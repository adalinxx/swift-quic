//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOQUIC
import NIOQUICHelpers

/// An established QUIC connection.
///
/// A connection multiplexes any number of independent, ordered, reliable
/// streams, plus optional unreliable datagrams (RFC 9221).
///
/// - Open outgoing streams with ``openBidirectionalStream()`` and
///   ``openUnidirectionalStream()``.
/// - Accept streams the peer opens by iterating ``incomingStreams``.
/// - Exchange unreliable messages with ``sendDatagram(_:)`` and ``datagrams``.
/// - Close with ``close(errorCode:reason:)``.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public final class QUICConnection: Sendable {
    /// Streams opened by the remote peer, in the order they arrive. The
    /// sequence ends when the connection closes.
    public let incomingStreams: IncomingStreams

    /// Unreliable datagrams received from the peer (RFC 9221).
    ///
    /// A bounded number of datagrams (see
    /// ``QUICTransportConfiguration/Datagrams-swift.struct/receiveBufferCount``)
    /// are buffered while you are not reading; beyond that the oldest are
    /// dropped, matching datagrams' unreliable semantics. The sequence ends
    /// when the connection closes.
    public let datagrams: Datagrams

    let channel: any Channel
    private let creator: NIOQUIC.QUICStreamCreator
    private let role: EndpointRole
    /// For client connections, the UDP socket owned (and closed) by this
    /// connection.
    private let ownedUDPChannel: (any Channel)?

    init(
        channel: any Channel,
        creator: NIOQUIC.QUICStreamCreator,
        role: EndpointRole,
        incomingStreams: IncomingStreams,
        datagrams: Datagrams,
        ownedUDPChannel: (any Channel)?
    ) {
        self.channel = channel
        self.creator = creator
        self.role = role
        self.incomingStreams = incomingStreams
        self.datagrams = datagrams
        self.ownedUDPChannel = ownedUDPChannel
    }

    deinit {
        // Safety net: tear everything down if the handle is dropped.
        self.channel.close(promise: nil)
        self.ownedUDPChannel?.close(promise: nil)
    }

    /// The local address of the underlying UDP socket.
    public var localAddress: SocketAddress? {
        self.channel.localAddress ?? self.channel.parent?.localAddress
    }

    /// The remote peer's address.
    public var remoteAddress: SocketAddress? {
        self.channel.remoteAddress ?? self.channel.parent?.remoteAddress
    }

    /// Opens a new bidirectional stream.
    public func openBidirectionalStream() async throws -> QUICStream {
        let role = self.role
        do {
            return try await self.creator.createBidirectionalStream { parameters in
                StreamFactory.makeStream(
                    channel: parameters.channel,
                    knownID: parameters.streamID.rawValue,
                    localRole: role
                )
            }.get()
        } catch {
            throw Self.mapStreamCreationError(error)
        }
    }

    /// Opens a new unidirectional (send-only) stream.
    public func openUnidirectionalStream() async throws -> QUICStream {
        let role = self.role
        do {
            return try await self.creator.createUnidirectionalStream { parameters in
                StreamFactory.makeStream(
                    channel: parameters.channel,
                    knownID: parameters.streamID.rawValue,
                    localRole: role
                )
            }.get()
        } catch {
            throw Self.mapStreamCreationError(error)
        }
    }

    /// Sends an unreliable datagram (RFC 9221).
    ///
    /// Delivery is not guaranteed and there is no retransmission; use streams
    /// for reliable data.
    ///
    /// - Throws: ``QUICConnectionError`` if the peer does not accept
    ///   datagrams, the payload exceeds the peer's advertised maximum size, or
    ///   the connection is closed.
    public func sendDatagram(_ datagram: ByteBuffer) async throws {
        do {
            let promise = self.channel.eventLoop.makePromise(of: Void.self)
            self.channel.writeAndFlush(datagram, promise: promise)
            // Cancellation-safe: the underlying QUIC stack can (rarely) leave
            // an early datagram write pending forever if its datagram flow
            // fails to attach; never wedge the calling task on that.
            try await withCancellableWait(promise.futureResult)
        } catch let error as NIOQUIC.QUICError {
            switch error {
            case .datagramTooLarge:
                throw QUICConnectionError(code: .datagramTooLarge)
            case .peerDoesNotAcceptDatagrams:
                throw QUICConnectionError(code: .datagramsNotSupportedByPeer)
            default:
                throw error
            }
        } catch let error as ChannelError where error == .ioOnClosedChannel {
            throw QUICConnectionError(code: .closed)
        }
    }

    /// Closes the connection cleanly with the "no error" code.
    public func close() async {
        await self.close(errorCode: .noError, reason: nil)
    }

    /// Closes the connection, sending `CONNECTION_CLOSE` with an
    /// application-defined error code and optional reason to the peer.
    public func close(errorCode: QUICApplicationErrorCode, reason: String? = nil) async {
        self.channel.pipeline.triggerUserOutboundEvent(
            QUICCloseConnectionEvent(code: errorCode.helperCode, reasonPhrase: reason),
            promise: nil
        )
        try? await self.channel.close().get()
        try? await self.channel.closeFuture.get()
        if let ownedUDPChannel = self.ownedUDPChannel {
            try? await ownedUDPChannel.close().get()
        }
    }

    /// Suspends until the connection has closed, for any reason.
    public func waitUntilClosed() async {
        try? await self.channel.closeFuture.get()
    }

    private static func mapStreamCreationError(_ error: any Error) -> any Error {
        if let quicError = error as? NIOQUIC.QUICError, quicError == .streamLimit {
            return QUICStreamError(code: .notWritable, applicationErrorCode: nil)
        }
        if let channelError = error as? ChannelError, channelError == .ioOnClosedChannel {
            return QUICConnectionError(code: .closed)
        }
        return error
    }

    /// The streams opened by the remote peer on a ``QUICConnection``.
    public struct IncomingStreams: AsyncSequence, Sendable {
        public typealias Element = QUICStream

        private let stream: AsyncStream<QUICStream>

        init(stream: AsyncStream<QUICStream>) {
            self.stream = stream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.stream.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            private var iterator: AsyncStream<QUICStream>.AsyncIterator

            init(iterator: AsyncStream<QUICStream>.AsyncIterator) {
                self.iterator = iterator
            }

            public mutating func next() async -> QUICStream? {
                await self.iterator.next()
            }
        }
    }

    /// The unreliable datagrams received on a ``QUICConnection``.
    public struct Datagrams: AsyncSequence, Sendable {
        public typealias Element = ByteBuffer

        private let stream: AsyncStream<ByteBuffer>

        init(stream: AsyncStream<ByteBuffer>) {
            self.stream = stream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.stream.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            private var iterator: AsyncStream<ByteBuffer>.AsyncIterator

            init(iterator: AsyncStream<ByteBuffer>.AsyncIterator) {
                self.iterator = iterator
            }

            public mutating func next() async -> ByteBuffer? {
                await self.iterator.next()
            }
        }
    }
}

@available(*, unavailable)
extension QUICConnection.IncomingStreams.AsyncIterator: Sendable {}

@available(*, unavailable)
extension QUICConnection.Datagrams.AsyncIterator: Sendable {}
