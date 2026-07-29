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
import NIOPosix
import QUIC
import Testing

@Suite(.timeLimit(.minutes(2)))
struct LocalBindAddressTests {
    /// Picks a currently-free UDP port by binding one ephemerally and reading
    /// back the assigned port.
    private func freeUDPPort() async throws -> Int {
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = channel.localAddress!.port!
        try await channel.close().get()
        return port
    }

    @Test
    func clientBindsRequestedLocalPort() async throws {
        let requestedPort = try await self.freeUDPPort()
        let localAddress = try SocketAddress(ipAddress: "127.0.0.1", port: requestedPort)

        try await withEchoServer { clientConfiguration, serverPort in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: serverPort,
                configuration: clientConfiguration,
                localAddress: localAddress
            ) { connection in
                // The mapping we would advertise for hole punching must be the
                // port we asked for, not an ephemeral one.
                #expect(connection.localAddress?.port == requestedPort)

                // And the connection must still actually work.
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("bound")
                try await stream.finish()
                let reply = try await stream.collect(upTo: 64)
                #expect(String(buffer: reply) == "bound")
            }
        }
    }

    @Test
    func defaultBindStillUsesEphemeralPort() async throws {
        try await withEchoServer { clientConfiguration, serverPort in
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: serverPort,
                configuration: clientConfiguration
            ) { connection in
                #expect((connection.localAddress?.port ?? 0) != 0)
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("ephemeral")
                try await stream.finish()
                let reply = try await stream.collect(upTo: 64)
                #expect(String(buffer: reply) == "ephemeral")
            }
        }
    }
}
