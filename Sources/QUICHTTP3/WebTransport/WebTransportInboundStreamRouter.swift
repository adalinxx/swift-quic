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

/// Sits at the head of every inbound QUIC stream on a WebTransport connection
/// and decides, from the stream's first varint, whether it is a WebTransport
/// stream (types `0x41` bidirectional / `0x54` unidirectional, followed by the
/// session ID) or a regular HTTP/3 stream (request, control, or QPACK).
///
/// WebTransport streams are stripped of their framing and delivered to the
/// owning session; everything else is handed to HTTP/3 with its bytes replayed
/// unchanged, so HTTP/3 request/control handling is unaffected.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class WebTransportInboundStreamRouter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let streamID: UInt64
    private let isUnidirectional: Bool
    private let wtHandler: WebTransportConnectionHandler
    private let handOffToHTTP3: @Sendable (any Channel) -> EventLoopFuture<Void>

    private var buffer = ByteBuffer()
    private enum State { case peeking, webTransport(AsyncStream<ByteBuffer>.Continuation), http3 }
    private var state: State = .peeking

    init(
        streamID: UInt64,
        wtHandler: WebTransportConnectionHandler,
        handOffToHTTP3: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) {
        self.streamID = streamID
        self.isUnidirectional = (streamID & 0x2) != 0
        self.wtHandler = wtHandler
        self.handOffToHTTP3 = handOffToHTTP3
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = self.unwrapInboundIn(data)
        switch self.state {
        case .peeking:
            self.buffer.writeBuffer(&incoming)
            self.tryDecide(context: context)
        case .webTransport(let continuation):
            continuation.yield(incoming)
        case .http3:
            context.fireChannelRead(data)
        }
    }

    private func tryDecide(context: ChannelHandlerContext) {
        var peek = self.buffer
        guard let firstVarint = QUICVarint.read(from: &peek) else { return }  // need more bytes
        let webTransportType: UInt64 = self.isUnidirectional ? 0x54 : 0x41

        if firstVarint == webTransportType {
            guard let sessionID = QUICVarint.read(from: &peek) else { return }  // need more bytes
            // Consume the WebTransport framing prefix.
            let prefixLength = self.buffer.readableBytes - peek.readableBytes
            self.buffer.moveReaderIndex(forwardBy: prefixLength)

            let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
            let inboundHandler = WebTransportStreamInboundHandler(continuation: continuation)
            let wtStream = WebTransportStream(
                id: self.streamID,
                isUnidirectional: self.isUnidirectional,
                isLocallyInitiated: false,
                channel: context.channel,
                inbound: WebTransportStream.Inbound(stream: stream)
            )
            self.state = .webTransport(continuation)
            // Deliver any bytes that arrived after the prefix, then swap in the
            // stream's own inbound handler and step out of the pipeline.
            if self.buffer.readableBytes > 0 {
                continuation.yield(self.buffer)
            }
            self.buffer.clear()
            do {
                try context.pipeline.syncOperations.addHandler(inboundHandler, position: .after(self))
            } catch {
                continuation.finish()
            }
            self.wtHandler.deliverInboundStream(wtStream, sessionID: sessionID)
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        } else {
            // Regular HTTP/3 stream: hand off and replay the buffered bytes.
            self.state = .http3
            let replay = self.buffer
            self.buffer.clear()
            // `bound` is created on the event loop (we are in channelRead) and
            // only read back on it, so the callback stays Sendable-safe.
            let bound = NIOLoopBound((context, self), eventLoop: context.eventLoop)
            self.handOffToHTTP3(context.channel).hop(to: context.eventLoop).whenComplete { _ in
                let (context, handler) = bound.value
                if replay.readableBytes > 0 {
                    context.fireChannelRead(handler.wrapInboundOut(replay))
                }
                context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if case .webTransport(let continuation) = self.state {
            continuation.finish()
        }
        context.fireChannelInactive()
    }
}
