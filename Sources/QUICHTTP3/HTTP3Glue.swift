//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// Wiring between NIOQUIC and swift-nio-http3, adapted from the reference
// integration in apple/swift-nio-http3's test suite. Kept internal; the public
// surface is HTTP3Server / HTTP3Client.

import HTTP3
import Logging
import NIOCore
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOQUICHelpers

import class NIOQUIC.AsyncVerifier
import class NIOQUIC.Authenticator
import struct NIOQUIC.QUICConfiguration
import class NIOQUIC.QUICHandler
import struct NIOQUIC.QUICMetrics
import struct NIOQUIC.QUICStreamCreator

typealias QUICHTTP3ConnectionHandler = HTTP3ConnectionHandler<QUICStreamCreator>

/// Adapts NIOQUIC's outbound-connection creation to the `HTTP3ConnectionCreator`
/// protocol the HTTP/3 client multiplexer drives.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
struct QUICConnectionCreator: HTTP3ConnectionCreator {
    let quicHandler: QUICHandler
    let connectionInitializer: @Sendable (any Channel, QUICStreamCreator) -> EventLoopFuture<any Channel>
    let inboundStreamInitializer: @Sendable (any Channel) -> EventLoopFuture<Void>

    func createNewConnection(
        serverName: String,
        remoteAddress: SocketAddress,
        connectionInitializer h3ConnectionInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<any Channel> {
        self.quicHandler.createOutboundConnection(
            serverName: serverName,
            remoteAddress: remoteAddress,
            connectionInitializer: { [connectionInitializer] connectionChannel, streamCreator in
                connectionInitializer(connectionChannel, streamCreator).flatMap { newConnectionChannel in
                    h3ConnectionInitializer(newConnectionChannel)
                }
            },
            inboundStreamInitializer: self.inboundStreamInitializer
        )
        // NIOQUIC returns (channel, streamCreator); the H3 multiplexer only
        // wants the channel.
        .map { channel, _ in channel }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
extension ChannelPipeline.SynchronousOperations {
    /// Installs the QUIC + HTTP/3 server handlers on a UDP channel and returns
    /// the connection multiplexer.
    func configureHTTP3Server<Output: Sendable>(
        channel: any Channel,
        settings: HTTP3Settings,
        quicConfiguration: QUICConfiguration,
        authenticator: Authenticator?,
        metrics: QUICMetrics?,
        logger: Logger,
        inboundRequestStreamInitializer:
            @Sendable @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>
    ) throws -> HTTP3ServerConnectionMultiplexer<Output, QUICStreamCreator> {
        let connectionMultiplexer = HTTP3ServerConnectionMultiplexer<Output, QUICStreamCreator>()
        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: quicConfiguration,
            asyncVerifier: nil,
            authenticator: authenticator,
            logger: logger,
            metrics: metrics,
            inboundConnectionInitializer: { connectionChannel, streamCreator in
                connectionChannel.eventLoop.makeCompletedFuture {
                    let loopBoundHandler: NIOLoopBoundBox<HTTP3ConnectionHandler<QUICStreamCreator>?> = .init(
                        nil,
                        eventLoop: connectionChannel.eventLoop
                    )
                    let connection = HTTP3ServerConnection(
                        connectionHandler: loopBoundHandler,
                        inboundStreamInitializer: inboundRequestStreamInitializer
                    )
                    let h3Handler = HTTP3ConnectionHandler.server(
                        eventLoop: connectionChannel.eventLoop,
                        configuration: .defaults,
                        settings: settings,
                        streamCreator: streamCreator,
                        logger: logger,
                        connection: connection
                    )
                    loopBoundHandler.value = h3Handler
                    try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                    connectionMultiplexer.yield(connection: connection)
                }
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self).flatMap {
                    h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {
                connectionMultiplexer.finish()
            }
        )
        try self.addHandler(quicHandler)
        return connectionMultiplexer
    }

    /// Installs the QUIC + HTTP/3 client handlers on a UDP channel and returns
    /// the connection multiplexer.
    func configureHTTP3Client(
        channel: any Channel,
        settings: HTTP3Settings,
        quicConfiguration: QUICConfiguration,
        asyncVerifier: AsyncVerifier?,
        metrics: QUICMetrics?,
        logger: Logger
    ) throws -> HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator> {
        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: quicConfiguration,
            asyncVerifier: asyncVerifier,
            authenticator: nil,
            logger: logger,
            metrics: metrics,
            inboundConnectionInitializer: { connectionChannel, _ in
                connectionChannel.close()
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self).flatMap {
                    h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {}
        )
        try self.addHandler(quicHandler)

        return HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>(
            eventLoop: self.eventLoop,
            createNewConnection: NIOLoopBound(
                QUICConnectionCreator(
                    quicHandler: quicHandler,
                    connectionInitializer: { connectionChannel, streamCreator in
                        connectionChannel.eventLoop.makeCompletedFuture {
                            let h3Handler = HTTP3ConnectionHandler.client(
                                eventLoop: connectionChannel.eventLoop,
                                configuration: .defaults,
                                settings: settings,
                                streamCreator: streamCreator,
                                logger: logger,
                                inboundPushStreamInitializer: { parameters in
                                    // Push streams are not surfaced; accept and
                                    // immediately let the channel close.
                                    parameters.channel.eventLoop.makeSucceededVoidFuture()
                                }
                            )
                            try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                            return connectionChannel
                        }
                    },
                    inboundStreamInitializer: { streamChannel in
                        streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self)
                            .flatMap { h3Handler in
                                h3Handler.inboundStreamReceived(streamChannel)
                            }
                    }
                ),
                eventLoop: self.eventLoop
            )
        )
    }
}
