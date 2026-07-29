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
public import Logging
import NIOCore
import NIOHTTPTypes
import NIOPosix
public import QUIC

@_spi(HTTP3AsyncInterface) import NIOHTTP3
import struct NIOQUIC.QUICStreamCreator
import HTTP3

/// Opens HTTP/3 connections to servers (RFC 9114).
///
/// ```swift
/// try await HTTP3Client.withConnection(to: "example.com", port: 443, configuration: config) { connection in
///     let response = try await connection.get("/")
///     print(response.status, String(buffer: response.body))
/// }
/// ```
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public enum HTTP3Client {
    /// Configuration for outgoing HTTP/3 connections.
    public struct Configuration: Sendable {
        /// The roots of trust used to verify the server's certificate.
        public var trustRoots: QUICTrustRoots = .system
        /// How thoroughly the server certificate is verified.
        public var certificateVerification: QUICCertificateVerification = .full
        /// QUIC transport tunables.
        public var transport: QUICTransportConfiguration = QUICTransportConfiguration()
        /// TLS 1.3 key exchange group. Defaults to X25519.
        public var keyExchangeGroup: QUICKeyExchangeGroup = .x25519
        /// The largest response body a request will collect, in bytes.
        /// Defaults to 16 MiB.
        public var maxResponseBodyBytes: Int = 16 * 1024 * 1024
        /// Metrics to record, via swift-metrics.
        public var metrics: QUICMetrics? = nil
        /// The logger used for transport-level events.
        public var logger: Logger = Logger(label: "swift-quic.h3.client")

        /// Creates a client configuration.
        public init() {}

        func quicConfiguration() -> QUICClient.Configuration {
            var configuration = QUICClient.Configuration(applicationProtocols: ["h3"])
            configuration.trustRoots = self.trustRoots
            configuration.certificateVerification = self.certificateVerification
            configuration.transport = self.transport
            configuration.keyExchangeGroup = self.keyExchangeGroup
            configuration.metrics = self.metrics
            configuration.logger = self.logger
            return configuration
        }
    }

    /// Connects to an HTTP/3 server, runs `body`, then closes the connection.
    public static func withConnection<Result: Sendable>(
        to host: String,
        port: Int,
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Connection) async throws -> Result
    ) async throws -> Result {
        let quicConfiguration = configuration.quicConfiguration()
        let nioqConfiguration = try quicConfiguration.makeNIOQUICConfiguration()
        let remoteAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
        let logger = configuration.logger
        let metrics = configuration.metrics

        let bindHost: String
        switch remoteAddress {
        case .v6: bindHost = "::"
        default: bindHost = "0.0.0.0"
        }

        let (udpChannel, multiplexer) = try await DatagramBootstrap(group: eventLoopGroup)
            // Batch datagram reads (recvmmsg on Linux). The receive allocator must
            // give each of the N message slots room for a full datagram, or the
            // vector read truncates packets (NIO splits one buffer N ways).
            .channelOption(.datagramVectorReadMessageCount, value: 8)
            .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8 * 2048))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: bindHost, port: 0) {
                channel -> EventLoopFuture<(
                    any Channel, HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>
                )> in
                channel.eventLoop.makeCompletedFuture {
                    let verifier = try quicConfiguration.makeAsyncVerifier(eventLoop: channel.eventLoop)
                    let mux = try channel.pipeline.syncOperations.configureHTTP3Client(
                        channel: channel,
                        settings: .init(),
                        quicConfiguration: nioqConfiguration,
                        asyncVerifier: verifier,
                        metrics: metrics,
                        logger: logger
                    )
                    return (channel, mux)
                }
            }

        do {
            let h3Connection = try await multiplexer.concurrencyView.createConnection(
                serverName: host,
                remoteAddress: remoteAddress,
                inboundPushStreamInitializer: { _ in
                    // Push streams are not surfaced yet.
                }
            )
            let connection = Connection(
                underlying: h3Connection,
                authority: "\(host):\(port)",
                maxResponseBodyBytes: configuration.maxResponseBodyBytes
            )
            let result = try await body(connection)
            try? await udpChannel.close().get()
            return result
        } catch {
            try? await udpChannel.close().get()
            throw error
        }
    }

    /// An established HTTP/3 connection. Issue requests with ``request(_:)`` or
    /// the ``get(_:headerFields:)`` convenience.
    public struct Connection: Sendable {
        typealias H3 = HTTP3ClientConnection<Void, QUICStreamCreator>
        let underlying: H3
        let authority: String
        private let maxResponseBodyBytes: Int

        init(underlying: H3, authority: String, maxResponseBodyBytes: Int) {
            self.underlying = underlying
            self.authority = authority
            self.maxResponseBodyBytes = maxResponseBodyBytes
        }

        /// Issues a GET request for `path`.
        public func get(_ path: String, headerFields: HTTPFields = [:]) async throws -> HTTP3Response {
            try await self.request(
                HTTP3Request(method: .get, path: path, headerFields: headerFields)
            )
        }

        /// Issues an HTTP/3 request and returns the collected response.
        public func request(_ request: HTTP3Request) async throws -> HTTP3Response {
            let maxBody = self.maxResponseBodyBytes
            var head = request.httpRequest
            if head.authority == nil {
                head.authority = self.authority
            }
            let body = request.body

            let stream = try await self.underlying.concurrencyView.createRequestStream {
                parameters -> EventLoopFuture<NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>> in
                parameters.channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                        wrappingChannelSynchronously: parameters.channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true)
                    )
                }
            }

            return try await stream.executeThenClose { inbound, outbound in
                try await outbound.write(.head(head))
                if let body, body.readableBytes > 0 {
                    try await outbound.write(.body(body))
                }
                outbound.finish()

                var status: HTTPResponse.Status?
                var headerFields = HTTPFields()
                var collected = ByteBuffer()
                var trailers = HTTPFields()
                for try await part in inbound {
                    switch part {
                    case .head(let response):
                        status = response.status
                        headerFields = response.headerFields
                    case .body(var buffer):
                        guard collected.readableBytes + buffer.readableBytes <= maxBody else {
                            throw HTTP3ClientError(code: .responseTooLarge)
                        }
                        collected.writeBuffer(&buffer)
                    case .end(let endTrailers):
                        if let endTrailers { trailers = endTrailers }
                    }
                }
                guard let status else {
                    throw HTTP3ClientError(code: .malformedResponse)
                }
                return HTTP3Response(
                    status: status, headerFields: headerFields, body: collected, trailers: trailers
                )
            }
        }
    }
}
