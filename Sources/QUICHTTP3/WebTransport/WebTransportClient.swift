//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
public import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTPTypes
import NIOPosix
public import QUIC

import HTTP3
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import struct NIOQUIC.QUICStreamCreator
import class NIOQUIC.QUICHandler

/// Errors surfaced by the WebTransport layer.
public struct WebTransportError: Error, Hashable, Sendable, CustomStringConvertible {
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        enum Base: Hashable, Sendable { case sessionRejected, connectionFailed, closed }
        var base: Base
        /// The server did not accept the session (non-2xx response to CONNECT).
        public static let sessionRejected = Code(base: .sessionRejected)
        /// The underlying QUIC/HTTP-3 connection could not be established.
        public static let connectionFailed = Code(base: .connectionFailed)
        /// The session or connection is closed.
        public static let closed = Code(base: .closed)
        public var description: String {
            switch self.base {
            case .sessionRejected: return "sessionRejected"
            case .connectionFailed: return "connectionFailed"
            case .closed: return "closed"
            }
        }
    }
    public var code: Code
    public init(code: Code) { self.code = code }
    public var description: String { "WebTransportError.\(self.code)" }
}

/// Opens WebTransport sessions to servers (draft-ietf-webtrans-http3).
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public enum WebTransportClient {
    /// Configuration for outgoing WebTransport sessions.
    public struct Configuration: Sendable {
        /// Roots of trust used to verify the server certificate.
        public var trustRoots: QUICTrustRoots = .system
        /// How thoroughly the server certificate is verified.
        public var certificateVerification: QUICCertificateVerification = .full
        /// QUIC transport tunables. Datagrams are required and force-enabled.
        public var transport: QUICTransportConfiguration = QUICTransportConfiguration()
        /// TLS 1.3 key exchange group.
        public var keyExchangeGroup: QUICKeyExchangeGroup = .x25519
        /// How many received datagrams to buffer before dropping the oldest.
        public var datagramReceiveBufferCount: Int = 64
        /// The logger used for transport-level events.
        public var logger: Logger = Logger(label: "swift-quic.webtransport.client")

        /// Creates a client configuration.
        public init() {}
    }

    /// Opens a WebTransport session to `host:port` at `path`.
    ///
    /// The returned session owns its UDP socket and QUIC connection; closing
    /// the session releases them.
    public static func connect(
        to host: String,
        port: Int,
        path: String = "/",
        configuration: Configuration = Configuration(),
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> WebTransportSession {
        var quicConfig = QUICClient.Configuration(applicationProtocols: ["h3"])
        quicConfig.trustRoots = configuration.trustRoots
        quicConfig.certificateVerification = configuration.certificateVerification
        quicConfig.transport = configuration.transport
        quicConfig.transport.datagrams.isEnabled = true
        quicConfig.keyExchangeGroup = configuration.keyExchangeGroup
        quicConfig.logger = configuration.logger
        let nioqConfiguration = try quicConfig.makeNIOQUICConfiguration()
        let settings = try WebTransportSettings.clientSettings()
        let remoteAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
        let logger = configuration.logger
        let bufferCount = configuration.datagramReceiveBufferCount

        let bindHost: String
        switch remoteAddress {
        case .v6: bindHost = "::"
        default: bindHost = "0.0.0.0"
        }

        let wtHandlerBox = NIOLockedValueBox<WebTransportConnectionHandler?>(nil)
        let finalQUICConfig = quicConfig

        // Build the QUIC handler and the HTTP/3 client multiplexer together on
        // the channel's event loop (mirrors HTTP3Client), avoiding any capture
        // of the non-Sendable QUIC handler across a suspension.
        let (udpChannel, multiplexer) = try await DatagramBootstrap(group: eventLoopGroup)
            .channelOption(.datagramVectorReadMessageCount, value: 8)
            .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8 * 2048))
            .bind(host: bindHost, port: 0) {
                channel -> EventLoopFuture<(
                    any Channel, HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>
                )> in
                channel.eventLoop.makeCompletedFuture {
                    let quicHandler = QUICHandler(
                        channel: channel,
                        quicConfiguration: nioqConfiguration,
                        asyncVerifier: try finalQUICConfig.makeAsyncVerifier(eventLoop: channel.eventLoop),
                        authenticator: nil,
                        logger: logger,
                        metrics: nil,
                        inboundConnectionInitializer: { connectionChannel, _ in connectionChannel.close() },
                        inboundStreamInitializer: { streamChannel in
                            streamChannel.parent!.pipeline
                                .handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self)
                                .flatMap { $0.inboundStreamReceived(streamChannel) }
                        },
                        noMoreConnections: {}
                    )
                    try channel.pipeline.syncOperations.addHandler(quicHandler)
                    let multiplexer = HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>(
                        eventLoop: channel.eventLoop,
                        createNewConnection: NIOLoopBound(
                            QUICConnectionCreator(
                                quicHandler: quicHandler,
                                connectionInitializer: { connectionChannel, streamCreator in
                                    connectionChannel.eventLoop.makeCompletedFuture {
                                        let wtHandler = WebTransportConnectionHandler()
                                        try connectionChannel.pipeline.syncOperations.addHandler(wtHandler)
                                        wtHandlerBox.withLockedValue { $0 = wtHandler }
                                        let h3Handler = HTTP3ConnectionHandler.client(
                                            eventLoop: connectionChannel.eventLoop,
                                            configuration: .defaults,
                                            settings: settings,
                                            streamCreator: streamCreator,
                                            logger: logger,
                                            inboundPushStreamInitializer: { params in
                                                params.channel.eventLoop.makeSucceededVoidFuture()
                                            }
                                        )
                                        try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                                        return connectionChannel
                                    }
                                },
                                inboundStreamInitializer: { streamChannel in
                                    streamChannel.parent!.pipeline
                                        .handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self)
                                        .flatMap { $0.inboundStreamReceived(streamChannel) }
                                }
                            ),
                            eventLoop: channel.eventLoop
                        )
                    )
                    return (channel, multiplexer)
                }
            }

        do {
            let h3Connection = try await multiplexer.concurrencyView.createConnection(
                serverName: host,
                remoteAddress: remoteAddress,
                inboundPushStreamInitializer: { (_: HTTP3StreamInitializerParameters) in () }
            )
            guard let wtHandler = wtHandlerBox.withLockedValue({ $0 }) else {
                throw WebTransportError(code: .connectionFailed)
            }

            var request = HTTPRequest(method: .connect, scheme: "https", authority: "\(host):\(port)", path: path)
            request.extendedConnectProtocol = "webtransport"

            let session = try await Self.establishSession(
                request: request,
                over: h3Connection,
                wtHandler: wtHandler,
                bufferCount: bufferCount,
                ownedUDPChannel: udpChannel
            )
            return session
        } catch {
            try? await udpChannel.close().get()
            throw error
        }
    }

    private static func establishSession(
        request: HTTPRequest,
        over h3Connection: HTTP3ClientConnection<Void, QUICStreamCreator>,
        wtHandler: WebTransportConnectionHandler,
        bufferCount: Int,
        ownedUDPChannel: any Channel
    ) async throws -> WebTransportSession {
        let streamIDBox = NIOLockedValueBox<UInt64?>(nil)
        let streamChannelBox = NIOLockedValueBox<(any Channel)?>(nil)
        let asyncChannel = try await h3Connection.concurrencyView.createRequestStream {
            (params: HTTP3StreamInitializerParameters) -> EventLoopFuture<
                NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>
            > in
            streamIDBox.withLockedValue { $0 = params.streamID.rawValue }
            streamChannelBox.withLockedValue { $0 = params.channel }
            return params.channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                    wrappingChannelSynchronously: params.channel,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
            }
        }
        let sessionID = streamIDBox.withLockedValue { $0 } ?? 0

        // Run the CONNECT stream for the session's lifetime in a detached task,
        // resuming the establishment continuation once the head arrives.
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WebTransportSession, any Error>) in
            let resumed = NIOLockedValueBox<Bool>(false)
            func resumeOnce(_ result: Result<WebTransportSession, any Error>) {
                let first = resumed.withLockedValue { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            Task {
                do {
                    try await asyncChannel.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(request))
                        var iterator = inbound.makeAsyncIterator()
                        guard case .head(let response)? = try await iterator.next(),
                            (200..<300).contains(response.status.code)
                        else {
                            resumeOnce(.failure(WebTransportError(code: .sessionRejected)))
                            outbound.finish()
                            return
                        }
                        let sink = WebTransportSessionSink(datagramBufferCount: bufferCount)
                        wtHandler.register(sessionID: sessionID, sink: sink)
                        let session = WebTransportSession(
                            sessionID: sessionID,
                            request: request,
                            sink: sink,
                            connectionHandler: wtHandler
                        )
                        resumeOnce(.success(session))

                        // Peer- or connection-initiated close ends the session.
                        streamChannelBox.withLockedValue { $0 }?.closeFuture
                            .whenComplete { _ in session.markClosed() }

                        for await _ in session.closeSignal {}
                        _ = iterator  // keep the inbound stream alive for the session's lifetime
                        wtHandler.unregister(sessionID: sessionID)
                        outbound.finish()
                    }
                    try? await ownedUDPChannel.close().get()
                } catch {
                    resumeOnce(.failure(error))
                    try? await ownedUDPChannel.close().get()
                }
            }
        }
    }
}
