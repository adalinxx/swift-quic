//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import QUIC
import Testing

@Suite(.timeLimit(.minutes(2)))
struct ConnectionTests {
    @Test
    func multipleConcurrentConnections() async throws {
        try await withEchoServer { clientConfiguration, port in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    group.addTask {
                        try await QUICClient.withConnection(
                            to: "127.0.0.1",
                            port: port,
                            configuration: clientConfiguration
                        ) { connection in
                            let stream = try await connection.openBidirectionalStream()
                            try await stream.send("connection-\(index)")
                            try await stream.finish()
                            let reply = try await stream.collect(upTo: 1024)
                            #expect(String(buffer: reply) == "connection-\(index)")
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    @Test
    func connectionAddressesAreVisible() async throws {
        try await withEchoServer { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let remote = try #require(connection.remoteAddress)
                #expect(remote.port == port)
                #expect(remote.ipAddress == "127.0.0.1")
                #expect(connection.localAddress != nil)
            }
        }
    }

    @Test
    func closingConnectionEndsServerSideStreams() async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        let serverSawClose = AsyncStream.makeStream(of: Void.self)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    // Consume streams until the connection closes; then signal.
                    for await _ in connection.incomingStreams {}
                    serverSawClose.continuation.yield(())
                    serverSawClose.continuation.finish()
                }
            }

            let connection = try await QUICClient.connect(
                to: "127.0.0.1",
                port: port,
                configuration: configurations.client
            )
            let stream = try await connection.openBidirectionalStream()
            try await stream.send("ping")
            try await stream.finish()
            await connection.close(errorCode: 3, reason: "done testing")

            // The server's incomingStreams sequence must end.
            var iterator = serverSawClose.stream.makeAsyncIterator()
            let signal: Void? = await iterator.next()
            #expect(signal != nil)

            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func waitUntilClosedReturnsWhenPeerCloses() async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    // Close every connection from the server side after the
                    // first stream finishes.
                    var iterator = connection.incomingStreams.makeAsyncIterator()
                    if let stream = await iterator.next() {
                        _ = try? await stream.collect(upTo: 1024)
                    }
                    await connection.close(errorCode: 5, reason: "server done")
                }
            }

            let connection = try await QUICClient.connect(
                to: "127.0.0.1",
                port: port,
                configuration: configurations.client
            )
            let stream = try await connection.openBidirectionalStream()
            try await stream.send("bye")
            try await stream.finish()

            // Must return rather than hang.
            await connection.waitUntilClosed()
            await connection.close()

            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func withConnectionClosesOnBodyExit() async throws {
        try await withEchoServer { clientConfiguration, port in
            let escaped = try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                connection
            }
            // After the scope exits the connection must be closed: opening a
            // stream fails.
            do {
                _ = try await escaped.openBidirectionalStream()
                Issue.record("expected stream creation on closed connection to fail")
            } catch {
                // Any error is acceptable; the connection is closed.
            }
        }
    }

    @Test
    func gracefulServerShutdownFinishesConnectionsSequence() async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    await echoConnectionHandler(connection)
                }
            }

            // Prove the server works, then shut it down.
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: configurations.client
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("pre-shutdown")
                try await stream.finish()
                _ = try await stream.collect(upTo: 1024)
            }

            try await server.shutdownGracefully(timeout: .seconds(5))

            // run() must return (the connections sequence finished) without
            // needing cancellation.
            try await group.waitForAll()
        }
    }
}
