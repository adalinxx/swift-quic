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
import NIOQUIC
import NIOPosix
import Synchronization

/// Opens QUIC connections to servers.
///
/// ```swift
/// var configuration = QUICClient.Configuration(applicationProtocols: ["my-proto"])
/// let connection = try await QUICClient.connect(
///     to: "example.com",
///     port: 4433,
///     configuration: configuration
/// )
/// defer { /* ... */ }
///
/// let stream = try await connection.openBidirectionalStream()
/// try await stream.send("hello")
/// try await stream.finish()
/// let reply = try await stream.collect(upTo: 1 << 20)
/// await connection.close()
/// ```
///
/// Prefer ``withConnection(to:port:configuration:eventLoopGroup:_:)`` where
/// possible: it guarantees the connection is closed when the body returns.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public enum QUICClient {
    /// Configuration for outgoing QUIC connections.
    public struct Configuration: Sendable {
        /// The ALPN protocol identifiers to offer, most-preferred first.
        /// Must not be empty.
        public var applicationProtocols: [String]

        /// The roots of trust used to verify the server's certificate.
        /// Defaults to the system trust store.
        public var trustRoots: QUICTrustRoots = .system

        /// How thoroughly the server certificate is verified. Defaults to
        /// full verification; only relax this in tests.
        public var certificateVerification: QUICCertificateVerification = .full

        /// QUIC transport tunables (flow control, stream limits, idle
        /// timeout, datagrams).
        public var transport: QUICTransportConfiguration = QUICTransportConfiguration()

        /// The TLS 1.3 key exchange group to use. Defaults to X25519; set
        /// ``QUICKeyExchangeGroup/x25519MLKEM768`` for hybrid post-quantum
        /// key exchange.
        public var keyExchangeGroup: QUICKeyExchangeGroup = .x25519

        /// How long ``connect(to:port:configuration:eventLoopGroup:)`` may
        /// take before failing with ``QUICConnectionError/Code-swift.struct/connectFailed``.
        /// Defaults to 10 seconds. Without this, a black-holed address would
        /// hold the caller until the idle timeout.
        public var connectTimeout: Duration = .seconds(10)

        /// Forces a QUIC version negotiation round trip. Mainly for testing.
        public var forceVersionNegotiation: Bool = false

        /// When set, TLS key material is appended to this file in
        /// `SSLKEYLOGFILE` format so tools like Wireshark can decrypt
        /// captures. Never enable in production.
        ///
        /// > Note: Currently a no-op pending key-log support in the underlying
        /// > QUIC stack (apple/swift-nio-quic#7).
        public var keyLogFile: String? = nil

        /// When set, qlog traces are written for each connection.
        public var qlog: QUICQLogConfiguration? = nil

        /// Metrics to record, via swift-metrics.
        public var metrics: QUICMetrics? = nil

        /// The logger used for transport-level events.
        public var logger: Logger = Logger(label: "swift-quic.client")

        /// Creates a client configuration.
        ///
        /// - Parameter applicationProtocols: The ALPN protocol identifiers to
        ///   offer. Must not be empty.
        public init(applicationProtocols: [String]) {
            self.applicationProtocols = applicationProtocols
        }
    }

    /// Connects to a QUIC server.
    ///
    /// The returned connection owns its UDP socket; closing the connection
    /// releases it.
    ///
    /// - Parameters:
    ///   - host: The server's hostname or IP address literal. Also used for
    ///     SNI and certificate hostname verification.
    ///   - port: The server's UDP port.
    ///   - configuration: The client configuration.
    ///   - localAddress: The local address to bind the UDP socket to. When
    ///     `nil` (the default) the socket binds an ephemeral port on the
    ///     wildcard host matching the server's address family. Set this to
    ///     bind a specific local port — required for NAT hole punching, where
    ///     the local mapping you advertise to the peer must correspond to the
    ///     socket QUIC actually uses. When set, `SO_REUSEADDR` is enabled so a
    ///     known port can be rebound promptly (e.g. after a STUN exchange).
    ///   - eventLoopGroup: The event loop group to run on. Defaults to the
    ///     shared singleton.
    public static func connect(
        to host: String,
        port: Int,
        configuration: Configuration,
        localAddress: SocketAddress? = nil,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> QUICConnection {
        let nioqConfiguration = try configuration.makeNIOQUICConfiguration()
        let remoteAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
        let datagramBufferCount = configuration.transport.datagrams.receiveBufferCount
        let logger = configuration.logger
        let metrics = configuration.metrics

        let channelInitializer: @Sendable (any Channel) -> EventLoopFuture<any Channel> = { channel in
            channel.eventLoop.makeCompletedFuture {
                let verifier = try configuration.makeAsyncVerifier(eventLoop: channel.eventLoop)
                let handler = QUICHandler(
                    channel: channel,
                    quicConfiguration: nioqConfiguration,
                    asyncVerifier: verifier,
                    authenticator: nil,
                    logger: logger,
                    metrics: metrics,
                    inboundConnectionInitializer: { connectionChannel, _ in
                        // Clients do not accept inbound connections.
                        connectionChannel.close()
                    },
                    inboundStreamInitializer: { streamChannel in
                        streamChannel.eventLoop.makeFailedFuture(
                            QUICConnectionError(
                                code: .closed,
                                message: "inbound stream on unknown client connection"
                            )
                        )
                    },
                    noMoreConnections: {}
                )
                try channel.pipeline.syncOperations.addHandler(handler)
                return channel
            }
        }

        let udpChannel: any Channel
        if let localAddress {
            // Binding a specific local port typically means the caller wants to
            // reuse a known mapping (NAT hole punching); allow prompt rebind.
            udpChannel = try await DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(to: localAddress, channelInitializer: channelInitializer)
        } else {
            let bindHost: String
            switch remoteAddress {
            case .v6:
                bindHost = "::"
            default:
                bindHost = "0.0.0.0"
            }
            udpChannel = try await DatagramBootstrap(group: eventLoopGroup)
            .bind(host: bindHost, port: 0, channelInitializer: channelInitializer)
        }

        do {
            let connectionBox: Mutex<QUICConnection?> = Mutex(nil)
            let registry = ConnectionRegistry()

            let connectionFuture = udpChannel.pipeline
                .handler(type: QUICHandler.self)
                .flatMap { handler in
                    handler.createOutboundConnection(
                        serverName: host,
                        remoteAddress: remoteAddress,
                        connectionInitializer: { connectionChannel, creator in
                            connectionChannel.eventLoop.makeCompletedFuture {
                                let (connection, sink) = try ConnectionAssembly.assemble(
                                    connectionChannel: connectionChannel,
                                    creator: creator,
                                    role: .client,
                                    datagramBufferCount: datagramBufferCount,
                                    ownedUDPChannel: udpChannel
                                )
                                connectionBox.withLock { $0 = connection }
                                // Route server-initiated streams to this connection.
                                registry.register(connectionChannel: connectionChannel, sink: sink)
                                connectionChannel.closeFuture.whenComplete { _ in
                                    registry.unregister(connectionChannel: connectionChannel)
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
                        }
                    )
                }

            // Race connection establishment against the connect timeout.
            // `withCancellableWait` makes the future await cancellable, so
            // the losing branch is always reaped.
            let timeout = configuration.connectTimeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let promise = udpChannel.eventLoop.makePromise(of: Void.self)
                    connectionFuture.map { _ in }.cascade(to: promise)
                    try await withCancellableWait(promise.futureResult)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw QUICConnectionError(
                        code: .connectFailed,
                        message: "connect timed out after \(timeout)"
                    )
                }
                do {
                    try await group.next()
                } catch {
                    group.cancelAll()
                    _ = try? await group.next()
                    throw error
                }
                group.cancelAll()
                // Drain the cancelled loser, swallowing its CancellationError.
                _ = try? await group.next()
            }

            guard let connection = connectionBox.withLock({ $0 }) else {
                throw QUICConnectionError(
                    code: .connectFailed,
                    message: "connection initializer did not run"
                )
            }
            return connection
        } catch {
            try? await udpChannel.close().get()
            throw error
        }
    }

    /// Connects to a QUIC server, runs `body`, and closes the connection when
    /// the body returns or throws.
    ///
    /// - Parameter localAddress: The local address to bind, or `nil` for an
    ///   ephemeral port. See ``connect(to:port:configuration:localAddress:eventLoopGroup:)``.
    public static func withConnection<Result: Sendable>(
        to host: String,
        port: Int,
        configuration: Configuration,
        localAddress: SocketAddress? = nil,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (QUICConnection) async throws -> Result
    ) async throws -> Result {
        let connection = try await self.connect(
            to: host,
            port: port,
            configuration: configuration,
            localAddress: localAddress,
            eventLoopGroup: eventLoopGroup
        )
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }
}
