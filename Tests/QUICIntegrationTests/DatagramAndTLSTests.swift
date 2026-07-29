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
struct DatagramTests {
    @Test
    func datagramEchoRoundTrip() async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    await withDiscardingTaskGroup { group in
                        // Echo every datagram back.
                        group.addTask {
                            for await datagram in connection.datagrams {
                                try? await connection.sendDatagram(datagram)
                            }
                        }
                        // Echo streams too (used by the client to synchronize).
                        await echoConnectionHandler(connection)
                    }
                }
            }

            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: configurations.client
            ) { connection in
                // Complete a stream round trip first: it guarantees the
                // datagram flow and the peer's advertisement are in place
                // before the first datagram write.
                let sync = try await connection.openBidirectionalStream()
                try await sync.send("sync")
                try await sync.finish()
                _ = try await sync.collect(upTo: 1024)

                let payload = ByteBuffer(string: "unreliable but fast")
                try await connection.sendDatagram(payload)

                var iterator = connection.datagrams.makeAsyncIterator()
                let echoed = await iterator.next()
                #expect(echoed == payload)
            }

            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func oversizedDatagramThrows() async throws {
        try await withEchoServer { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                // Complete a stream round trip first so the peer's datagram
                // advertisement has definitely arrived.
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("sync")
                try await stream.finish()
                _ = try await stream.collect(upTo: 1024)

                let oversized = ByteBuffer(repeating: 0x41, count: 512 * 1024)
                do {
                    try await connection.sendDatagram(oversized)
                    Issue.record("expected oversized datagram to throw")
                } catch let error as QUICConnectionError {
                    #expect(error.code == .datagramTooLarge)
                }
            }
        }
    }

    @Test
    func datagramsToPeerWithDatagramsDisabledThrow() async throws {
        var configurations = try TestConfigurations()
        // The server refuses datagrams entirely.
        configurations.server.transport.datagrams.isEnabled = false

        try await withEchoServer(configurations: configurations) { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                // Sync so the transport parameters are known.
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("sync")
                try await stream.finish()
                _ = try await stream.collect(upTo: 1024)

                do {
                    try await connection.sendDatagram(ByteBuffer(string: "hi"))
                    Issue.record("expected datagram to unsupporting peer to throw")
                } catch let error as QUICConnectionError {
                    #expect(
                        error.code == .datagramsNotSupportedByPeer
                            || error.code == .datagramTooLarge
                    )
                }
            }
        }
    }
}

@Suite(.timeLimit(.minutes(2)))
struct TLSBehaviorTests {
    @Test
    func untrustedCertificateIsRejected() async throws {
        var configurations = try TestConfigurations()
        // Trust a *different* self-signed certificate than the server presents.
        let otherIdentity = try QUICIdentity.selfSigned(commonName: "unrelated")
        configurations.client.trustRoots = .certificates([otherIdentity.certificate])

        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    await echoConnectionHandler(connection)
                }
            }

            do {
                let connection = try await QUICClient.connect(
                    to: "127.0.0.1",
                    port: port,
                    configuration: configurations.client
                )
                // Some failure modes only surface on first use.
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("should never arrive")
                try await stream.finish()
                _ = try await stream.collect(upTo: 1024)
                Issue.record("expected TLS verification failure")
                await connection.close()
            } catch {
                // Expected: the handshake (or the first exchange) fails.
            }

            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func disabledVerificationAcceptsUntrustedCertificate() async throws {
        var configurations = try TestConfigurations()
        configurations.client.trustRoots = .system
        configurations.client.certificateVerification = .none

        try await withEchoServer(configurations: configurations) { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("trusted anyway")
                try await stream.finish()
                let reply = try await stream.collect(upTo: 1024)
                #expect(String(buffer: reply) == "trusted anyway")
            }
        }
    }

    @Test
    func alpnMismatchFailsHandshake() async throws {
        let configurations = try TestConfigurations(
            applicationProtocols: ["server-proto"],
            clientApplicationProtocols: ["client-proto"]
        )
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    await echoConnectionHandler(connection)
                }
            }

            do {
                let connection = try await QUICClient.connect(
                    to: "127.0.0.1",
                    port: port,
                    configuration: configurations.client
                )
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("should never arrive")
                try await stream.finish()
                _ = try await stream.collect(upTo: 1024)
                Issue.record("expected ALPN mismatch to fail the handshake")
                await connection.close()
            } catch {
                // Expected.
            }

            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func postQuantumKeyExchangeConnects() async throws {
        var configurations = try TestConfigurations()
        configurations.server.keyExchangeGroup = .x25519MLKEM768
        configurations.client.keyExchangeGroup = .x25519MLKEM768

        try await withEchoServer(configurations: configurations) { clientConfiguration, port in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("post-quantum hello")
                try await stream.finish()
                let reply = try await stream.collect(upTo: 1024)
                #expect(String(buffer: reply) == "post-quantum hello")
            }
        }
    }
}
