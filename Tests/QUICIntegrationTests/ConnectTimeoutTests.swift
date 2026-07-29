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
struct ConnectTimeoutTests {
    @Test
    func connectToBlackHoleTimesOut() async throws {
        // A proxy that drops 100% of packets is a perfect black hole: the
        // handshake can never complete, so only the connect timeout can end
        // the attempt.
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let blackHole = try await LossyUDPProxy(
            serverAddress: server.localAddress,
            impairments: .init(
                dropProbability: 1.0,
                reorderProbability: 0,
                duplicateProbability: 0,
                seed: 1
            )
        )

        var clientConfiguration = configurations.client
        clientConfiguration.connectTimeout = .seconds(2)

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let connection = try await QUICClient.connect(
                to: "127.0.0.1",
                port: blackHole.localAddress.port!,
                configuration: clientConfiguration
            )
            Issue.record("expected connect to time out")
            await connection.close()
        } catch let error as QUICConnectionError {
            #expect(error.code == .connectFailed)
            let elapsed = clock.now - start
            // Fired by our timeout, well before the 30s idle timeout.
            #expect(elapsed < .seconds(10))
        }

        await blackHole.close()
        await server.close()
    }

    @Test
    func connectWithinTimeoutIsUnaffected() async throws {
        try await withEchoServer { clientConfiguration, port in
            var configuration = clientConfiguration
            configuration.connectTimeout = .seconds(5)
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: configuration
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("fast")
                try await stream.finish()
                let reply = try await stream.collect(upTo: 64)
                #expect(String(buffer: reply) == "fast")
            }
        }
    }
}
