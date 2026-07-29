//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import QUIC

/// A matched pair of server and client configurations sharing an ephemeral
/// self-signed certificate.
struct TestConfigurations {
    var server: QUICServer.Configuration
    var client: QUICClient.Configuration
    var selfSigned: QUICSelfSignedIdentity

    init(
        applicationProtocols: [String] = ["swift-quic-test"],
        clientApplicationProtocols: [String]? = nil
    ) throws {
        let selfSigned = try QUICIdentity.selfSigned(
            commonName: "swift-quic-test",
            dnsNames: ["localhost"],
            ipAddresses: ["127.0.0.1", "::1"]
        )
        self.selfSigned = selfSigned

        var server = QUICServer.Configuration(
            identity: selfSigned.identity,
            applicationProtocols: applicationProtocols
        )
        var logger = Logger(label: "test-server")
        logger.logLevel = .warning
        server.logger = logger
        self.server = server

        var client = QUICClient.Configuration(
            applicationProtocols: clientApplicationProtocols ?? applicationProtocols
        )
        client.trustRoots = .certificates([selfSigned.certificate])
        var clientLogger = Logger(label: "test-client")
        clientLogger.logLevel = .warning
        client.logger = clientLogger
        self.client = client
    }
}

/// Binds an echo server on 127.0.0.1, runs it in a child task, invokes `body`
/// with the client configuration and the server's port, then tears everything
/// down.
///
/// The echo behavior: every incoming bidirectional stream is echoed
/// chunk-by-chunk and finished when the peer finishes.
func withEchoServer(
    configurations: TestConfigurations? = nil,
    _ body: @escaping @Sendable (QUICClient.Configuration, Int) async throws -> Void
) async throws {
    let configurations = try configurations ?? TestConfigurations()
    let server = try await QUICServer.bind(
        host: "127.0.0.1",
        configuration: configurations.server
    )
    let port = server.localAddress.port!

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await server.run { connection in
                await echoConnectionHandler(connection)
            }
        }
        // Run the client body inline; then wind the server down.
        try await body(configurations.client, port)
        group.cancelAll()
    }
    await server.close()
}

/// Echoes every incoming stream on a connection, concurrently.
@Sendable
func echoConnectionHandler(_ connection: QUICConnection) async {
    await withDiscardingTaskGroup { group in
        for await stream in connection.incomingStreams {
            group.addTask {
                do {
                    for try await chunk in stream.inbound {
                        if stream.isWritable {
                            try await stream.send(chunk)
                        }
                    }
                    if stream.isWritable {
                        try await stream.finish()
                    }
                } catch {
                    // The peer went away or reset the stream; nothing to do.
                }
            }
        }
    }
}

/// Deterministic pseudo-random bytes for payload integrity checks.
func makePatternedBuffer(byteCount: Int, seed: UInt8 = 7) -> ByteBuffer {
    var bytes = [UInt8]()
    bytes.reserveCapacity(byteCount)
    var state = seed
    for _ in 0..<byteCount {
        state = state &* 31 &+ 17
        bytes.append(state)
    }
    return ByteBuffer(bytes: bytes)
}
