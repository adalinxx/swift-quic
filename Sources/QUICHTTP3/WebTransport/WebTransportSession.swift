//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import HTTPTypes
import NIOCore
public import struct NIOCore.ByteBuffer
import NIOConcurrencyHelpers

/// An established WebTransport session (draft-ietf-webtrans-http3) over an
/// HTTP/3 extended-CONNECT stream.
///
/// Exchange unreliable messages with ``sendDatagram(_:)`` and ``datagrams``.
/// End the session with ``close()``; it also ends when the peer closes it or
/// the underlying connection drops.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public final class WebTransportSession: Sendable {
    /// The session identifier (the CONNECT stream's QUIC stream ID).
    public let sessionID: UInt64

    /// The request head that opened the session (the extended CONNECT request).
    public let request: HTTPRequest

    /// Unreliable datagrams received on this session (RFC 9297).
    public let datagrams: Datagrams

    private let connectionHandler: WebTransportConnectionHandler
    private let closeContinuation: AsyncStream<Void>.Continuation
    let closeSignal: AsyncStream<Void>
    private let closed = NIOLockedValueBox<Bool>(false)

    init(
        sessionID: UInt64,
        request: HTTPRequest,
        sink: WebTransportSessionSink,
        connectionHandler: WebTransportConnectionHandler
    ) {
        self.sessionID = sessionID
        self.request = request
        self.datagrams = Datagrams(stream: sink.datagrams)
        self.connectionHandler = connectionHandler
        (self.closeSignal, self.closeContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// Sends an unreliable datagram on this session.
    ///
    /// Delivery is not guaranteed; there is no retransmission. Oversized
    /// datagrams (beyond the peer's advertised limit) are dropped by the
    /// transport.
    public func sendDatagram(_ payload: ByteBuffer) {
        self.connectionHandler.sendDatagram(sessionID: self.sessionID, payload: payload)
    }

    /// Sends the UTF-8 bytes of `string` as a datagram.
    public func sendDatagram(_ string: String) {
        self.sendDatagram(ByteBuffer(string: string))
    }

    /// Closes the session. Idempotent.
    public func close() {
        let wasOpen = self.closed.withLockedValue { closed -> Bool in
            defer { closed = true }
            return !closed
        }
        if wasOpen {
            self.closeContinuation.finish()
        }
    }

    /// Whether ``close()`` has been called or the session has ended.
    public var isClosed: Bool {
        self.closed.withLockedValue { $0 }
    }

    /// Marks the session closed without re-signalling (used when the owning
    /// stream/connection ends).
    func markClosed() {
        self.closed.withLockedValue { $0 = true }
        self.closeContinuation.finish()
    }

    /// The unreliable datagrams received on a ``WebTransportSession``.
    public struct Datagrams: AsyncSequence, Sendable {
        public typealias Element = ByteBuffer
        private let stream: AsyncStream<ByteBuffer>
        init(stream: AsyncStream<ByteBuffer>) { self.stream = stream }
        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.stream.makeAsyncIterator())
        }
        public struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: AsyncStream<ByteBuffer>.AsyncIterator
            public mutating func next() async -> ByteBuffer? { await self.iterator.next() }
        }
    }
}

@available(*, unavailable)
extension WebTransportSession.Datagrams.AsyncIterator: Sendable {}
