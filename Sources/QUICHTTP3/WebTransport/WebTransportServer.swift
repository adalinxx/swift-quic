//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import Logging
import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTPTypes
import NIOPosix
public import QUIC

import HTTP3
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import struct NIOQUIC.QUICStreamCreator
import NIOQUICHelpers
import class NIOQUIC.QUICHandler

/// A WebTransport server (draft-ietf-webtrans-http3) bound to a UDP port.
///
/// ```swift
/// let server = try await WebTransportServer.bind(
///     host: "127.0.0.1", configuration: .init(identity: selfSigned.identity))
/// try await server.run { session in
///     for await datagram in session.datagrams {
///         session.sendDatagram(datagram)   // echo
///     }
/// }
/// ```
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public final class WebTransportServer: Sendable {
    /// Configuration for a ``WebTransportServer``.
    public struct Configuration: Sendable {
        /// The TLS identity presented to clients.
        public var identity: QUICIdentity
        /// The server name used during the TLS handshake.
        public var serverName: String = "localhost"
        /// QUIC transport tunables. Datagrams are required and force-enabled.
        public var transport: QUICTransportConfiguration = QUICTransportConfiguration()
        /// TLS 1.3 key exchange group.
        public var keyExchangeGroup: QUICKeyExchangeGroup = .x25519
        /// Maximum concurrent WebTransport sessions advertised to peers.
        public var maxSessions: UInt64 = 16
        /// How many received datagrams to buffer per session before dropping
        /// the oldest.
        public var datagramReceiveBufferCount: Int = 64
        /// Metrics to record.
        public var metrics: QUICMetrics? = nil
        /// The logger used for transport-level events.
        public var logger: Logger = Logger(label: "swift-quic.webtransport.server")

        /// Creates a server configuration.
        public init(identity: QUICIdentity) {
            self.identity = identity
        }
    }

    private let udpChannel: any Channel
    private let sessions: AsyncStream<WebTransportSession>
    private let sessionsContinuation: AsyncStream<WebTransportSession>.Continuation
    private let registry: WebTransportConnectionRegistry
    private let datagramBufferCount: Int

    /// The address the server is listening on.
    public let localAddress: SocketAddress

    private init(
        udpChannel: any Channel,
        sessions: AsyncStream<WebTransportSession>,
        sessionsContinuation: AsyncStream<WebTransportSession>.Continuation,
        registry: WebTransportConnectionRegistry,
        localAddress: SocketAddress,
        datagramBufferCount: Int
    ) {
        self.udpChannel = udpChannel
        self.sessions = sessions
        self.sessionsContinuation = sessionsContinuation
        self.registry = registry
        self.localAddress = localAddress
        self.datagramBufferCount = datagramBufferCount
    }

    deinit {
        self.udpChannel.close(promise: nil)
    }

    /// Binds a WebTransport server.
    public static func bind(
        host: String = "0.0.0.0",
        port: Int = 0,
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> WebTransportServer {
        var quicConfig = QUICServer.Configuration(identity: configuration.identity, applicationProtocols: ["h3"])
        quicConfig.serverName = configuration.serverName
        quicConfig.transport = configuration.transport
        quicConfig.transport.datagrams.isEnabled = true
        quicConfig.keyExchangeGroup = configuration.keyExchangeGroup
        quicConfig.metrics = configuration.metrics
        quicConfig.logger = configuration.logger
        let (nioqConfiguration, authenticator) = try quicConfig.makeNIOQUICConfiguration()

        let settings = try WebTransportSettings.serverSettings(maxSessions: configuration.maxSessions)
        let logger = configuration.logger
        let metrics = configuration.metrics
        let registry = WebTransportConnectionRegistry()
        let bufferCount = configuration.datagramReceiveBufferCount
        let (sessions, sessionsContinuation) = AsyncStream.makeStream(of: WebTransportSession.self)

        let udpChannel = try await DatagramBootstrap(group: eventLoopGroup)
            .channelOption(.datagramVectorReadMessageCount, value: 8)
            .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8 * 2048))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel -> EventLoopFuture<any Channel> in
                channel.eventLoop.makeCompletedFuture {
                    let quicHandler = QUICHandler(
                        channel: channel,
                        quicConfiguration: nioqConfiguration,
                        asyncVerifier: nil,
                        authenticator: authenticator,
                        logger: logger,
                        metrics: metrics,
                        inboundConnectionInitializer: { connectionChannel, streamCreator in
                            connectionChannel.eventLoop.makeCompletedFuture {
                                let wtHandler = WebTransportConnectionHandler()
                                try connectionChannel.pipeline.syncOperations.addHandler(wtHandler)
                                registry.register(
                                    connectionChannel: connectionChannel,
                                    handler: wtHandler,
                                    streamCreator: streamCreator
                                )
                                connectionChannel.closeFuture.whenComplete { _ in
                                    registry.unregister(connectionChannel: connectionChannel)
                                }

                                let loopBound: NIOLoopBoundBox<HTTP3ConnectionHandler<QUICStreamCreator>?> =
                                    .init(nil, eventLoop: connectionChannel.eventLoop)
                                let h3Connection = HTTP3ServerConnection(
                                    connectionHandler: loopBound,
                                    inboundStreamInitializer: {
                                        (params: HTTP3StreamInitializerParameters) -> EventLoopFuture<
                                            WebTransportServer.RequestStream
                                        > in
                                        let connID = params.channel.parent.map(ObjectIdentifier.init)
                                        return params.channel.eventLoop.makeCompletedFuture {
                                            let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                                wrappingChannelSynchronously: params.channel,
                                                configuration: .init(isOutboundHalfClosureEnabled: true)
                                            )
                                            return RequestStream(
                                                asyncChannel: asyncChannel,
                                                streamChannel: params.channel,
                                                streamID: params.streamID.rawValue,
                                                connectionID: connID
                                            )
                                        }
                                    }
                                )
                                let h3Handler = HTTP3ConnectionHandler.server(
                                    eventLoop: connectionChannel.eventLoop,
                                    configuration: .defaults,
                                    settings: settings,
                                    streamCreator: streamCreator,
                                    logger: logger,
                                    connection: h3Connection
                                )
                                loopBound.value = h3Handler
                                try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                                registry.registerConnection(connectionChannel: connectionChannel, h3: h3Connection)
                            }
                        },
                        inboundStreamInitializer: { streamChannel in
                            Self.routeInboundStream(streamChannel, registry: registry)
                        },
                        noMoreConnections: {
                            sessionsContinuation.finish()
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(quicHandler)
                    return channel
                }
            }

        guard let localAddress = udpChannel.localAddress else {
            try? await udpChannel.close().get()
            throw QUICConnectionError(code: .connectFailed, message: "server bound without a local address")
        }

        let server = WebTransportServer(
            udpChannel: udpChannel,
            sessions: sessions,
            sessionsContinuation: sessionsContinuation,
            registry: registry,
            localAddress: localAddress,
            datagramBufferCount: bufferCount
        )
        // Drive the accept loop: iterate H3 connections as they arrive and pull
        // their inbound CONNECT streams into sessions.
        server.startAccepting(eventLoopGroup: eventLoopGroup)
        return server
    }

    /// A wrapped inbound request stream.
    struct RequestStream: Sendable {
        let asyncChannel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>
        let streamChannel: any Channel
        let streamID: UInt64
        let connectionID: ObjectIdentifier?
    }

    private func startAccepting(eventLoopGroup: any EventLoopGroup) {
        let registry = self.registry
        let sessionsContinuation = self.sessionsContinuation
        let bufferCount = self.datagramBufferCount
        Task {
            await withDiscardingTaskGroup { group in
                for await connection in registry.connections {
                    group.addTask {
                        await withDiscardingTaskGroup { streamGroup in
                            for await stream in connection.inboundStreams {
                                streamGroup.addTask {
                                    await Self.handleCONNECT(
                                        stream: stream,
                                        registry: registry,
                                        sessionsContinuation: sessionsContinuation,
                                        bufferCount: bufferCount
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Routes an inbound QUIC stream: WebTransport streams go to their session,
    /// everything else (CONNECT requests, control, QPACK) to HTTP/3.
    static func routeInboundStream(
        _ streamChannel: any Channel,
        registry: WebTransportConnectionRegistry
    ) -> EventLoopFuture<Void> {
        let handOff: @Sendable (any Channel) -> EventLoopFuture<Void> = { channel in
            channel.parent!.pipeline
                .handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self)
                .flatMap { $0.inboundStreamReceived(channel) }
        }
        guard let parent = streamChannel.parent,
            let handler = registry.handler(forConnectionID: ObjectIdentifier(parent))
        else {
            return handOff(streamChannel)
        }
        return streamChannel.getOption(.quicStreamID).flatMap { streamID in
            streamChannel.eventLoop.makeCompletedFuture {
                let router = WebTransportInboundStreamRouter(
                    streamID: streamID,
                    wtHandler: handler,
                    handOffToHTTP3: handOff
                )
                try streamChannel.pipeline.syncOperations.addHandler(router)
            }
        }
    }

    private static func handleCONNECT(
        stream: RequestStream,
        registry: WebTransportConnectionRegistry,
        sessionsContinuation: AsyncStream<WebTransportSession>.Continuation,
        bufferCount: Int
    ) async {
        guard let connID = stream.connectionID,
            let entry = registry.entry(forConnectionID: connID)
        else {
            return
        }
        let wtHandler = entry.handler
        do {
            try await stream.asyncChannel.executeThenClose { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                guard case .head(let request)? = try await iterator.next(),
                    request.method == .connect,
                    request.extendedConnectProtocol == "webtransport"
                else {
                    try? await outbound.write(.head(HTTPResponse(status: .badRequest)))
                    outbound.finish()
                    return
                }

                // A 2xx response establishes the session.
                try await outbound.write(.head(HTTPResponse(status: .ok)))

                let sink = WebTransportSessionSink(datagramBufferCount: bufferCount)
                wtHandler.register(sessionID: stream.streamID, sink: sink)
                let session = WebTransportSession(
                    sessionID: stream.streamID,
                    request: request,
                    sink: sink,
                    connectionHandler: wtHandler,
                    streamCreator: entry.streamCreator
                )
                sessionsContinuation.yield(session)

                // Peer- or connection-initiated close ends the session too.
                stream.streamChannel.closeFuture.whenComplete { _ in session.markClosed() }

                // Keep the CONNECT stream open until the session closes.
                for await _ in session.closeSignal {}
                _ = iterator  // keep the inbound stream alive for the session's lifetime
                wtHandler.unregister(sessionID: stream.streamID)
                outbound.finish()
            }
        } catch {
            // Peer reset the stream or the connection dropped.
        }
    }

    /// Serves WebTransport sessions until the server shuts down, running
    /// `handler` in its own task per session.
    public func run(_ handler: @escaping @Sendable (WebTransportSession) async -> Void) async {
        await withDiscardingTaskGroup { group in
            for await session in self.sessions {
                group.addTask { await handler(session) }
            }
        }
    }

    /// The sessions accepted by this server, for manual iteration.
    public var incomingSessions: AsyncStream<WebTransportSession> {
        self.sessions
    }

    /// Closes the server's socket, dropping all sessions.
    public func close() async {
        try? await self.udpChannel.close().get()
    }
}
