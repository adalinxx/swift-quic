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
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import struct NIOQUIC.QUICStreamCreator

/// Tracks each QUIC connection's WebTransport datagram handler and surfaces
/// accepted HTTP/3 connections, so inbound CONNECT streams can be matched to
/// the handler that carries their datagrams.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class WebTransportConnectionRegistry: Sendable {
    typealias H3Connection = HTTP3ServerConnection<WebTransportServer.RequestStream, QUICStreamCreator>

    private let handlers = NIOLockedValueBox<[ObjectIdentifier: WebTransportConnectionHandler]>([:])
    let connections: AsyncStream<H3Connection>
    private let connectionsContinuation: AsyncStream<H3Connection>.Continuation

    init() {
        (self.connections, self.connectionsContinuation) = AsyncStream.makeStream(of: H3Connection.self)
    }

    func register(connectionChannel: any Channel, handler: WebTransportConnectionHandler) {
        self.handlers.withLockedValue { $0[ObjectIdentifier(connectionChannel)] = handler }
    }

    func unregister(connectionChannel: any Channel) {
        self.handlers.withLockedValue { _ = $0.removeValue(forKey: ObjectIdentifier(connectionChannel)) }
    }

    func handler(forConnectionID id: ObjectIdentifier) -> WebTransportConnectionHandler? {
        self.handlers.withLockedValue { $0[id] }
    }

    func registerConnection(connectionChannel: any Channel, h3: H3Connection) {
        self.connectionsContinuation.yield(h3)
    }

    func finish() {
        self.connectionsContinuation.finish()
    }
}
