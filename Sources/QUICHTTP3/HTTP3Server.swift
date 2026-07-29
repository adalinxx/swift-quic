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
import NIOHTTPTypes
import HTTPTypes
import NIOPosix
public import QUIC

@_spi(HTTP3AsyncInterface) import NIOHTTP3
import struct NIOQUIC.QUICStreamCreator
import struct NIOHTTP3.HTTP3StreamInitializerParameters
import HTTP3

/// An HTTP/3 server (RFC 9114) bound to a UDP port.
///
/// ```swift
/// let server = try await HTTP3Server.bind(
///     host: "127.0.0.1",
///     configuration: .init(identity: selfSigned.identity)
/// )
/// try await server.run { request in
///     HTTP3Response(status: .ok, string: "you asked for \(request.path)")
/// }
/// ```
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public final class HTTP3Server: Sendable {
    /// Configuration for an ``HTTP3Server``.
    public struct Configuration: Sendable {
        /// The TLS identity presented to clients.
        public var identity: QUICIdentity
        /// The server name used during the TLS handshake.
        public var serverName: String = "localhost"
        /// QUIC transport tunables.
        public var transport: QUICTransportConfiguration = QUICTransportConfiguration()
        /// TLS 1.3 key exchange group. Defaults to X25519.
        public var keyExchangeGroup: QUICKeyExchangeGroup = .x25519
        /// Validate client addresses with a Retry packet before accepting.
        public var sendRetry: Bool = false
        /// The largest request body the handler will collect, in bytes.
        /// Defaults to 16 MiB.
        public var maxRequestBodyBytes: Int = 16 * 1024 * 1024
        /// Metrics to record, via swift-metrics.
        public var metrics: QUICMetrics? = nil
        /// The logger used for transport-level events.
        public var logger: Logger = Logger(label: "swift-quic.h3.server")

        /// Creates a server configuration.
        /// - Parameter identity: The TLS identity presented to clients.
        public init(identity: QUICIdentity) {
            self.identity = identity
        }

        /// The QUIC server configuration this maps onto, with ALPN forced to `h3`.
        func quicConfiguration() -> QUICServer.Configuration {
            var configuration = QUICServer.Configuration(identity: self.identity, applicationProtocols: ["h3"])
            configuration.serverName = self.serverName
            configuration.transport = self.transport
            configuration.keyExchangeGroup = self.keyExchangeGroup
            configuration.sendRetry = self.sendRetry
            configuration.metrics = self.metrics
            configuration.logger = self.logger
            return configuration
        }
    }

    private let udpChannel: any Channel
    let multiplexer: HTTP3ServerConnectionMultiplexer<RequestStream, QUICStreamCreator>
    private let maxRequestBodyBytes: Int

    /// The address the server is listening on.
    public let localAddress: SocketAddress

    private init(
        udpChannel: any Channel,
        multiplexer: HTTP3ServerConnectionMultiplexer<RequestStream, QUICStreamCreator>,
        localAddress: SocketAddress,
        maxRequestBodyBytes: Int
    ) {
        self.udpChannel = udpChannel
        self.multiplexer = multiplexer
        self.localAddress = localAddress
        self.maxRequestBodyBytes = maxRequestBodyBytes
    }

    deinit {
        self.udpChannel.close(promise: nil)
    }

    /// A wrapped request stream channel.
    struct RequestStream: Sendable {
        let asyncChannel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>
    }

    /// Binds an HTTP/3 server.
    public static func bind(
        host: String = "0.0.0.0",
        port: Int = 0,
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> HTTP3Server {
        let (nioqConfiguration, authenticator) = try configuration.quicConfiguration().makeNIOQUICConfiguration()
        let logger = configuration.logger
        let metrics = configuration.metrics

        let (udpChannel, multiplexer) = try await DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) {
                channel -> EventLoopFuture<(
                    any Channel, HTTP3ServerConnectionMultiplexer<RequestStream, QUICStreamCreator>
                )> in
                channel.eventLoop.makeCompletedFuture {
                    let mux = try channel.pipeline.syncOperations.configureHTTP3Server(
                        channel: channel,
                        settings: .init(),
                        quicConfiguration: nioqConfiguration,
                        authenticator: authenticator,
                        metrics: metrics,
                        logger: logger,
                        inboundRequestStreamInitializer: { parameters in
                            parameters.channel.eventLoop.makeCompletedFuture {
                                let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                    wrappingChannelSynchronously: parameters.channel,
                                    configuration: .init(isOutboundHalfClosureEnabled: true)
                                )
                                return RequestStream(asyncChannel: asyncChannel)
                            }
                        }
                    )
                    return (channel, mux)
                }
            }

        guard let localAddress = udpChannel.localAddress else {
            try? await udpChannel.close().get()
            throw QUICConnectionError(code: .connectFailed, message: "server bound without a local address")
        }
        return HTTP3Server(
            udpChannel: udpChannel,
            multiplexer: multiplexer,
            localAddress: localAddress,
            maxRequestBodyBytes: configuration.maxRequestBodyBytes
        )
    }

    /// Serves requests until the server shuts down, invoking `handler` for each
    /// request and sending back the response it returns.
    ///
    /// Each connection and each request runs in its own child task.
    public func run(
        _ handler: @escaping @Sendable (HTTP3ServerRequest) async -> HTTP3Response
    ) async throws {
        let maxBody = self.maxRequestBodyBytes
        try await withThrowingDiscardingTaskGroup { connectionGroup in
            for try await connection in self.multiplexer.inboundConnections {
                connectionGroup.addTask {
                    await withDiscardingTaskGroup { streamGroup in
                        for await stream in connection.inboundStreams {
                            streamGroup.addTask {
                                await Self.handle(stream: stream, maxBody: maxBody, handler: handler)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func handle(
        stream: RequestStream,
        maxBody: Int,
        handler: @Sendable (HTTP3ServerRequest) async -> HTTP3Response
    ) async {
        do {
            try await stream.asyncChannel.executeThenClose { inbound, outbound in
                var head: HTTPRequest?
                var body = ByteBuffer()
                for try await part in inbound {
                    switch part {
                    case .head(let request):
                        head = request
                    case .body(var buffer):
                        guard body.readableBytes + buffer.readableBytes <= maxBody else {
                            try await outbound.write(.head(HTTPResponse(status: .contentTooLarge)))
                            outbound.finish()
                            return
                        }
                        body.writeBuffer(&buffer)
                    case .end:
                        break
                    }
                }
                guard let head else { return }

                let response = await handler(HTTP3ServerRequest(head: head, body: body))
                var responseHead = response.httpResponse
                responseHead.headerFields[.contentLength] = String(response.body.readableBytes)
                try await outbound.write(.head(responseHead))
                if response.body.readableBytes > 0 {
                    try await outbound.write(.body(response.body))
                }
                try await outbound.write(.end(nil))
                outbound.finish()
            }
        } catch {
            // The peer reset the stream or the connection went away; nothing to do.
        }
    }

    /// Gracefully shuts the server down.
    public func close() async {
        try? await self.udpChannel.close().get()
    }
}
