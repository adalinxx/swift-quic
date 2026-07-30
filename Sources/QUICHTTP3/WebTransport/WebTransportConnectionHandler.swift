//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore

/// The receive side of a WebTransport session's datagrams, plus the inbound WT
/// streams belonging to it.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class WebTransportSessionSink: Sendable {
    let datagrams: AsyncStream<ByteBuffer>
    let datagramContinuation: AsyncStream<ByteBuffer>.Continuation
    let incomingStreams: AsyncStream<WebTransportStream>
    let incomingStreamContinuation: AsyncStream<WebTransportStream>.Continuation

    init(datagramBufferCount: Int) {
        (self.datagrams, self.datagramContinuation) = AsyncStream.makeStream(
            of: ByteBuffer.self,
            bufferingPolicy: .bufferingNewest(datagramBufferCount)
        )
        (self.incomingStreams, self.incomingStreamContinuation) = AsyncStream.makeStream(of: WebTransportStream.self)
    }

    func finish() {
        self.datagramContinuation.finish()
        self.incomingStreamContinuation.finish()
    }
}

/// Routes WebTransport datagrams on a QUIC connection channel: inbound QUIC
/// datagrams are demultiplexed to the owning session by their quarter-stream-id
/// (RFC 9297), and outbound datagrams are framed and sent.
///
/// Installed on the connection channel *before* the HTTP/3 connection handler,
/// so it consumes datagram reads (which HTTP/3 does not want) and originates
/// datagram writes toward the QUIC datagram handler (bypassing HTTP/3).
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class WebTransportConnectionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let sinks = NIOLockedValueBox<[UInt64: WebTransportSessionSink]>([:])
    private let context = NIOLockedValueBox<ChannelHandlerContext?>(nil)
    private let eventLoop = NIOLockedValueBox<(any EventLoop)?>(nil)

    func handlerAdded(context: ChannelHandlerContext) {
        self.context.withLockedValue { $0 = context }
        self.eventLoop.withLockedValue { $0 = context.eventLoop }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context.withLockedValue { $0 = nil }
        let sinks = self.sinks.withLockedValue { current in
            defer { current = [:] }
            return current
        }
        for sink in sinks.values { sink.finish() }
    }

    /// Registers a session's sink so its datagrams and inbound streams are
    /// delivered.
    func register(sessionID: UInt64, sink: WebTransportSessionSink) {
        self.sinks.withLockedValue { $0[sessionID] = sink }
    }

    func unregister(sessionID: UInt64) {
        let sink = self.sinks.withLockedValue { $0.removeValue(forKey: sessionID) }
        sink?.finish()
    }

    /// Delivers an accepted inbound WebTransport stream to its session.
    func deliverInboundStream(_ stream: WebTransportStream, sessionID: UInt64) {
        if let sink = self.sinks.withLockedValue({ $0[sessionID] }) {
            sink.incomingStreamContinuation.yield(stream)
        } else {
            Task { await stream.close() }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Connection-channel byte reads are QUIC datagrams. Decode the owning
        // session and deliver; consume regardless (HTTP/3 never wants these).
        let datagram = self.unwrapInboundIn(data)
        if let (sessionID, payload) = HTTP3DatagramCodec.decodeDatagram(datagram),
            let sink = self.sinks.withLockedValue({ $0[sessionID] })
        {
            sink.datagramContinuation.yield(payload)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let sinks = self.sinks.withLockedValue { $0 }
        for sink in sinks.values { sink.finish() }
        context.fireChannelInactive()
    }

    /// Sends a datagram for `sessionID`. Thread-safe; hops to the event loop.
    func sendDatagram(sessionID: UInt64, payload: ByteBuffer) {
        guard let eventLoop = self.eventLoop.withLockedValue({ $0 }) else { return }
        let encoded = HTTP3DatagramCodec.encodeDatagram(streamID: sessionID, payload: payload)
        // `self` is @unchecked Sendable and `encoded` is Sendable; the context
        // is read and used only here, on its own event loop.
        eventLoop.execute {
            guard let context = self.context.withLockedValue({ $0 }) else { return }
            context.writeAndFlush(self.wrapOutboundOut(encoded), promise: nil)
        }
    }
}
