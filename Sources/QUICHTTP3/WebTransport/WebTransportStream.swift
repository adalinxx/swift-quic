//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import struct NIOCore.ByteBuffer
import NIOConcurrencyHelpers
import NIOCore

/// A WebTransport stream: a QUIC stream belonging to a session, carrying raw
/// application bytes after its WebTransport framing (stream type + session ID)
/// has been stripped.
///
/// Read with ``inbound``; write with ``send(_:)`` and end with ``finish()``.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public final class WebTransportStream: Sendable {
    /// The QUIC stream ID.
    public let id: UInt64
    /// Whether the stream is unidirectional (send-only for the opener,
    /// receive-only for the acceptor).
    public let isUnidirectional: Bool
    /// Whether this endpoint opened the stream.
    public let isLocallyInitiated: Bool

    /// The bytes received on this stream, in order, ending when the peer
    /// finishes it.
    public let inbound: Inbound

    private let channel: any Channel
    private let writable: NIOLockedValueBox<Bool>

    init(
        id: UInt64,
        isUnidirectional: Bool,
        isLocallyInitiated: Bool,
        channel: any Channel,
        inbound: Inbound
    ) {
        self.id = id
        self.isUnidirectional = isUnidirectional
        self.isLocallyInitiated = isLocallyInitiated
        self.channel = channel
        self.inbound = inbound
        // A locally-opened unidirectional stream is send-only; a remotely-opened
        // one is receive-only. Bidirectional streams are always writable.
        self.writable = NIOLockedValueBox(!isUnidirectional || isLocallyInitiated)
    }

    /// Sends bytes on the stream.
    public func send(_ buffer: ByteBuffer) async throws {
        guard self.writable.withLockedValue({ $0 }) else {
            throw WebTransportError(code: .closed)
        }
        try await self.channel.writeAndFlush(buffer).get()
    }

    /// Sends the UTF-8 bytes of `string`.
    public func send(_ string: String) async throws {
        try await self.send(ByteBuffer(string: string))
    }

    /// Signals the end of this endpoint's writes (sends a FIN).
    public func finish() async {
        self.writable.withLockedValue { $0 = false }
        try? await self.channel.close(mode: .output).get()
    }

    /// Closes the stream in both directions.
    public func close() async {
        self.writable.withLockedValue { $0 = false }
        try? await self.channel.close(mode: .all).get()
    }

    /// Reads the whole remaining stream into one buffer, up to `maxBytes`.
    public func collect(upTo maxBytes: Int) async throws -> ByteBuffer {
        var acc = ByteBuffer()
        for try await var chunk in self.inbound {
            guard acc.readableBytes + chunk.readableBytes <= maxBytes else {
                throw WebTransportError(code: .closed)
            }
            acc.writeBuffer(&chunk)
        }
        return acc
    }

    /// The bytes received on a ``WebTransportStream``.
    public struct Inbound: AsyncSequence, Sendable {
        public typealias Element = ByteBuffer
        let stream: AsyncStream<ByteBuffer>
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
extension WebTransportStream.Inbound.AsyncIterator: Sendable {}

/// Feeds a WebTransport stream channel's inbound bytes into its
/// ``WebTransportStream/inbound`` sequence.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class WebTransportStreamInboundHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<ByteBuffer>.Continuation

    init(continuation: AsyncStream<ByteBuffer>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.continuation.yield(self.unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelEvent, case ChannelEvent.inputClosed = event {
            self.continuation.finish()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.continuation.finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.continuation.finish()
    }
}
