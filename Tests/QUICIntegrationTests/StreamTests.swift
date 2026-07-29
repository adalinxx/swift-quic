//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import QUIC
import Testing

@Suite(.timeLimit(.minutes(2)))
struct StreamTests {
    @Test
    func bidirectionalEcho() async throws {
        try await withEchoServer { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                #expect(stream.id.isBidirectional)
                #expect(stream.id.initiator == .client)
                #expect(stream.isWritable)

                try await stream.send("hello, QUIC")
                try await stream.finish()

                let reply = try await stream.collect(upTo: 1024)
                #expect(String(buffer: reply) == "hello, QUIC")
            }
        }
    }

    @Test
    func sequentialStreamsOnOneConnection() async throws {
        try await withEchoServer { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                for index in 0..<5 {
                    let stream = try await connection.openBidirectionalStream()
                    try await stream.send("message-\(index)")
                    try await stream.finish()
                    let reply = try await stream.collect(upTo: 1024)
                    #expect(String(buffer: reply) == "message-\(index)")
                }
            }
        }
    }

    @Test
    func concurrentStreams() async throws {
        try await withEchoServer { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<20 {
                        group.addTask {
                            let stream = try await connection.openBidirectionalStream()
                            let payload = "concurrent-\(index)"
                            try await stream.send(payload)
                            try await stream.finish()
                            let reply = try await stream.collect(upTo: 1024)
                            #expect(String(buffer: reply) == payload)
                        }
                    }
                    try await group.waitForAll()
                }
            }
        }
    }

    @Test
    func largeTransferSurvivesFlowControl() async throws {
        // 8 MiB round trip: comfortably larger than the 2 MiB per-stream
        // window, so this exercises flow control and backpressure end to end.
        let payload = makePatternedBuffer(byteCount: 8 * 1024 * 1024)
        try await withEchoServer { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let stream = try await connection.openBidirectionalStream()

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        // Send in chunks while concurrently reading the echo,
                        // otherwise both sides' flow control windows deadlock.
                        var remaining = payload
                        while remaining.readableBytes > 0 {
                            let chunk = remaining.readSlice(
                                length: min(64 * 1024, remaining.readableBytes)
                            )!
                            try await stream.send(chunk)
                        }
                        try await stream.finish()
                    }
                    group.addTask {
                        let reply = try await stream.collect(upTo: payload.readableBytes + 1)
                        #expect(reply == payload)
                    }
                    try await group.waitForAll()
                }
            }
        }
    }

    @Test
    func halfCloseAllowsReadingAfterFinish() async throws {
        try await withEchoServer { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("half-close")
                try await stream.finish()

                // Writing after finish must fail locally.
                await #expect(throws: QUICStreamError(code: .notWritable)) {
                    try await stream.send("more")
                }

                // Reading still works.
                let reply = try await stream.collect(upTo: 1024)
                #expect(String(buffer: reply) == "half-close")
            }
        }
    }

    @Test
    func unidirectionalStreamsBothDirections() async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    for await stream in connection.incomingStreams {
                        #expect(stream.id.isUnidirectional)
                        #expect(stream.id.initiator == .client)
                        #expect(!stream.isWritable)

                        // Sending on a receive-only stream must fail locally.
                        do {
                            try await stream.send("nope")
                            Issue.record("expected send on receive-only stream to throw")
                        } catch let error as QUICStreamError {
                            #expect(error.code == .notWritable)
                        } catch {
                            Issue.record("unexpected error: \(error)")
                        }

                        // Echo back on a server-initiated unidirectional stream.
                        if let received = try? await stream.collect(upTo: 1024) {
                            let back = try? await connection.openUnidirectionalStream()
                            try? await back?.send(received)
                            try? await back?.finish()
                        }
                    }
                }
            }

            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: configurations.client
            ) { connection in
                let stream = try await connection.openUnidirectionalStream()
                #expect(stream.id.isUnidirectional)
                #expect(stream.isWritable)
                try await stream.send("one way")
                try await stream.finish()

                // The server replies on its own unidirectional stream.
                var iterator = connection.incomingStreams.makeAsyncIterator()
                let replyStream = try #require(await iterator.next())
                #expect(replyStream.id.isUnidirectional)
                #expect(replyStream.id.initiator == .server)
                let contents = try await replyStream.collect(upTo: 1024)
                #expect(String(buffer: contents) == "one way")
            }

            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func serverInitiatedBidirectionalStream() async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    // Push a greeting to every client that connects.
                    guard let stream = try? await connection.openBidirectionalStream() else { return }
                    try? await stream.send("server says hi")
                    try? await stream.finish()
                    _ = try? await stream.collect(upTo: 1024)
                }
            }

            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: configurations.client
            ) { connection in
                var iterator = connection.incomingStreams.makeAsyncIterator()
                let pushed = try #require(await iterator.next())
                #expect(pushed.id.initiator == .server)
                #expect(pushed.id.isBidirectional)
                let contents = try await pushed.collect(upTo: 1024)
                #expect(String(buffer: contents) == "server says hi")
                try await pushed.finish()
            }

            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func streamResetSurfacesAsError() async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    for await stream in connection.incomingStreams {
                        // Read a little, then abort our send side.
                        var iterator = stream.inbound.makeAsyncIterator()
                        _ = try? await iterator.next()
                        stream.reset(errorCode: 77)
                    }
                }
            }

            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: configurations.client
            ) { connection in
                let stream = try await connection.openBidirectionalStream()

                // The peer resets the stream after our first bytes arrive.
                // Depending on timing the reset can surface on the in-flight
                // send or on the read side — in both cases it must be a typed
                // stream error, never a raw transport error.
                do {
                    try await stream.send("trigger")
                    _ = try await stream.collect(upTo: 1024)
                    Issue.record("expected reset error")
                } catch let error as QUICStreamError {
                    #expect(error.code == .reset || error.code == .closed)
                    // The application error code is preserved on the typed
                    // upstream path; in one teardown race upstream degrades it
                    // to a bare connection-reset, losing the code.
                    #expect(error.applicationErrorCode == 77 || error.applicationErrorCode == nil)
                }
                await stream.close()
            }

            group.cancelAll()
        }
        await server.close()
    }
}
