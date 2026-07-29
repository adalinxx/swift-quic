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
import Synchronization

/// Receives inbound stream channels for one connection and yields wrapped
/// ``QUICStream``s into the connection's `incomingStreams` sequence.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class StreamSink: Sendable {
    private let continuation: AsyncStream<QUICStream>.Continuation
    private let role: EndpointRole

    init(continuation: AsyncStream<QUICStream>.Continuation, role: EndpointRole) {
        self.continuation = continuation
        self.role = role
    }

    /// The per-stream channel initializer for inbound streams.
    func initializeInboundStream(_ channel: any Channel) -> EventLoopFuture<Void> {
        StreamFactory.makeStream(channel: channel, knownID: nil, localRole: self.role)
            .map { stream in
                switch self.continuation.yield(stream) {
                case .terminated:
                    // The connection is gone; nobody will ever see this stream.
                    Task { await stream.close() }
                default:
                    ()
                }
            }
    }

    func finish() {
        self.continuation.finish()
    }
}

/// Wires up a freshly-initialized NIOQUIC connection channel into a public
/// ``QUICConnection``.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
enum ConnectionAssembly {
    /// Must run on the connection channel's event loop, from within the
    /// connection initializer.
    static func assemble(
        connectionChannel: any Channel,
        creator: NIOQUIC.QUICStreamCreator,
        role: EndpointRole,
        datagramBufferCount: Int,
        ownedUDPChannel: (any Channel)?
    ) throws -> (QUICConnection, StreamSink) {
        let (incoming, incomingContinuation) = AsyncStream.makeStream(of: QUICStream.self)
        let sink = StreamSink(continuation: incomingContinuation, role: role)

        let (datagramStream, datagramContinuation) = AsyncStream.makeStream(
            of: ByteBuffer.self,
            bufferingPolicy: .bufferingNewest(datagramBufferCount)
        )
        try connectionChannel.pipeline.syncOperations.addHandler(
            DatagramBridgeHandler(continuation: datagramContinuation)
        )

        connectionChannel.closeFuture.whenComplete { _ in
            sink.finish()
            datagramContinuation.finish()
        }

        let connection = QUICConnection(
            channel: connectionChannel,
            creator: creator,
            role: role,
            incomingStreams: QUICConnection.IncomingStreams(stream: incoming),
            datagrams: QUICConnection.Datagrams(stream: datagramStream),
            ownedUDPChannel: ownedUDPChannel
        )
        return (connection, sink)
    }
}

/// Routes inbound stream channels to the right connection's ``StreamSink`` by
/// their parent (connection) channel identity. Used on the server, where a
/// single stream initializer closure serves every connection.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class ConnectionRegistry: Sendable {
    private let sinks: Mutex<[ObjectIdentifier: StreamSink]> = Mutex([:])

    func register(connectionChannel: any Channel, sink: StreamSink) {
        let id = ObjectIdentifier(connectionChannel)
        self.sinks.withLock { $0[id] = sink }
    }

    func unregister(connectionChannel: any Channel) {
        let id = ObjectIdentifier(connectionChannel)
        self.sinks.withLock { _ = $0.removeValue(forKey: id) }
    }

    func sink(forConnectionChannel channel: any Channel) -> StreamSink? {
        let id = ObjectIdentifier(channel)
        return self.sinks.withLock { $0[id] }
    }
}

/// Forwards datagrams read from the connection channel into the public
/// `datagrams` sequence.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class DatagramBridgeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<ByteBuffer>.Continuation

    init(continuation: AsyncStream<ByteBuffer>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Dropped datagrams are fine: they are unreliable by definition.
        _ = self.continuation.yield(self.unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.continuation.finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.continuation.finish()
    }
}
