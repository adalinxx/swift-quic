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
import NIOCore
public import NIOQUIC
import NIOPosix

/// Connection- and transport-level metrics, recorded via swift-metrics.
/// See `NIOQUIC.QUICMetrics` for the available dimensions.
public typealias QUICMetrics = NIOQUIC.QUICMetrics

/// A QUIC server bound to a UDP port.
///
/// ```swift
/// let server = try await QUICServer.bind(
///     host: "127.0.0.1",
///     configuration: .init(
///         identity: .certificateChain(pemFile: "cert.pem", privateKeyPEMFile: "key.pem"),
///         applicationProtocols: ["my-proto"]
///     )
/// )
/// print("listening on \(server.localAddress)")
///
/// try await server.run { connection in
///     for await stream in connection.incomingStreams {
///         // handle the stream
///     }
/// }
/// ```
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public final class QUICServer: Sendable {
    /// Configuration for a ``QUICServer``.
    public struct Configuration: Sendable {
        /// The TLS identity presented to clients.
        public var identity: QUICIdentity

        /// The ALPN protocol identifiers this server accepts, most-preferred
        /// first. Must not be empty.
        public var applicationProtocols: [String]

        /// The server name used during the TLS handshake.
        public var serverName: String = "localhost"

        /// QUIC transport tunables (flow control, stream limits, idle
        /// timeout, datagrams).
        public var transport: QUICTransportConfiguration = QUICTransportConfiguration()

        /// The TLS 1.3 key exchange group to use. Defaults to X25519; set
        /// ``QUICKeyExchangeGroup/x25519MLKEM768`` for hybrid post-quantum
        /// key exchange.
        public var keyExchangeGroup: QUICKeyExchangeGroup = .x25519

        /// Whether to validate client addresses with a Retry packet before
        /// accepting a connection. Adds a round trip, but protects against
        /// address spoofing. Defaults to `false`.
        public var sendRetry: Bool = false

        /// When set, TLS key material is appended to this file in
        /// `SSLKEYLOGFILE` format so tools like Wireshark can decrypt captures.
        /// Never enable in production.
        ///
        /// > Note: Currently a no-op pending key-log support in the underlying
        /// > QUIC stack (apple/swift-nio-quic#7).
        public var keyLogFile: String? = nil

        /// When set, qlog traces are written for each connection.
        public var qlog: QUICQLogConfiguration? = nil

        /// Metrics to record, via swift-metrics.
        public var metrics: QUICMetrics? = nil

        /// The logger used for transport-level events.
        public var logger: Logger = Logger(label: "swift-quic.server")

        /// Creates a server configuration.
        ///
        /// - Parameters:
        ///   - identity: The TLS identity presented to clients.
        ///   - applicationProtocols: The ALPN protocol identifiers this server
        ///     accepts. Must not be empty.
        public init(identity: QUICIdentity, applicationProtocols: [String]) {
            self.identity = identity
            self.applicationProtocols = applicationProtocols
        }
    }

    private let udpChannel: any Channel
    private let handlerHandle: QUICHandlerHandle

    /// The address the server is listening on. Useful when binding port `0`.
    public let localAddress: SocketAddress

    /// The connections accepted by this server, in arrival order. The
    /// sequence ends when the server shuts down.
    ///
    /// Iterate this directly for full control, or use ``run(_:)`` to get a
    /// task-per-connection accept loop for free.
    public let connections: Connections

    private init(
        udpChannel: any Channel,
        handlerHandle: QUICHandlerHandle,
        localAddress: SocketAddress,
        connections: Connections
    ) {
        self.udpChannel = udpChannel
        self.handlerHandle = handlerHandle
        self.localAddress = localAddress
        self.connections = connections
    }

    deinit {
        self.udpChannel.close(promise: nil)
    }

    /// Binds a QUIC server.
    ///
    /// - Parameters:
    ///   - host: The local address to bind. Defaults to all IPv4 interfaces.
    ///   - port: The UDP port to bind. Defaults to `0` (pick a free port; read
    ///     it back from ``localAddress``).
    ///   - configuration: The server configuration.
    ///   - eventLoopGroup: The event loop group to run on. Defaults to the
    ///     shared singleton.
    public static func bind(
        host: String = "0.0.0.0",
        port: Int = 0,
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> QUICServer {
        let (nioqConfiguration, authenticator) = try configuration.makeNIOQUICConfiguration()
        let registry = ConnectionRegistry()
        let (connectionStream, connectionContinuation) = AsyncStream.makeStream(of: QUICConnection.self)
        let datagramBufferCount = configuration.transport.datagrams.receiveBufferCount
        let logger = configuration.logger
        let metrics = configuration.metrics

        let (udpChannel, handlerHandle) = try await DatagramBootstrap(group: eventLoopGroup)
            .channelOption(.datagramVectorReadMessageCount, value: 8)            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = QUICHandler(
                        channel: channel,
                        quicConfiguration: nioqConfiguration,
                        asyncVerifier: nil,
                        authenticator: authenticator,
                        logger: logger,
                        metrics: metrics,
                        inboundConnectionInitializer: { connectionChannel, creator in
                            connectionChannel.eventLoop.makeCompletedFuture {
                                let (connection, sink) = try ConnectionAssembly.assemble(
                                    connectionChannel: connectionChannel,
                                    creator: creator,
                                    role: .server,
                                    datagramBufferCount: datagramBufferCount,
                                    ownedUDPChannel: nil
                                )
                                registry.register(connectionChannel: connectionChannel, sink: sink)
                                connectionChannel.closeFuture.whenComplete { _ in
                                    registry.unregister(connectionChannel: connectionChannel)
                                }
                                switch connectionContinuation.yield(connection) {
                                case .terminated:
                                    // Nobody is accepting connections any more.
                                    connectionChannel.close(promise: nil)
                                default:
                                    ()
                                }
                            }
                        },
                        inboundStreamInitializer: { streamChannel in
                            guard
                                let parent = streamChannel.parent,
                                let sink = registry.sink(forConnectionChannel: parent)
                            else {
                                return streamChannel.eventLoop.makeFailedFuture(
                                    QUICConnectionError(
                                        code: .closed,
                                        message: "stream arrived for unknown connection"
                                    )
                                )
                            }
                            return sink.initializeInboundStream(streamChannel)
                        },
                        noMoreConnections: {
                            connectionContinuation.finish()
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return (channel, handler.makeHandle())
                }
            }

        guard let localAddress = udpChannel.localAddress else {
            try? await udpChannel.close().get()
            throw QUICConnectionError(code: .connectFailed, message: "server bound without a local address")
        }

        return QUICServer(
            udpChannel: udpChannel,
            handlerHandle: handlerHandle,
            localAddress: localAddress,
            connections: Connections(stream: connectionStream)
        )
    }

    /// Accepts connections until the server shuts down, running `handler` in
    /// its own child task for each connection.
    ///
    /// Cancelling the surrounding task stops the accept loop and cancels all
    /// per-connection tasks.
    public func run(
        _ handler: @escaping @Sendable (QUICConnection) async -> Void
    ) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            for await connection in self.connections {
                group.addTask {
                    await handler(connection)
                }
            }
        }
    }

    /// Gracefully shuts the server down: stops accepting new connections and
    /// gives existing connections until `timeout` to finish before closing
    /// them forcibly.
    public func shutdownGracefully(timeout: Duration = .seconds(30)) async throws {
        let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
        try await self.handlerHandle.shutdownGracefully(deadline: .now() + .nanoseconds(nanoseconds))
        try? await self.udpChannel.close().get()
    }

    /// Closes the server's UDP socket immediately, dropping all connections.
    public func close() async {
        try? await self.udpChannel.close().get()
    }

    /// The connections accepted by a ``QUICServer``.
    public struct Connections: AsyncSequence, Sendable {
        public typealias Element = QUICConnection

        private let stream: AsyncStream<QUICConnection>

        init(stream: AsyncStream<QUICConnection>) {
            self.stream = stream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.stream.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            private var iterator: AsyncStream<QUICConnection>.AsyncIterator

            init(iterator: AsyncStream<QUICConnection>.AsyncIterator) {
                self.iterator = iterator
            }

            public mutating func next() async -> QUICConnection? {
                await self.iterator.next()
            }
        }
    }
}

@available(*, unavailable)
extension QUICServer.Connections.AsyncIterator: Sendable {}
