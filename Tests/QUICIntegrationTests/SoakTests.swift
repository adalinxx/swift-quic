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

/// Long-running stress test. Disabled by default; enable with
/// `SWIFT_QUIC_SOAK=1 swift test --filter SoakTests`. CI runs it nightly.
@Suite(.timeLimit(.minutes(5)))
struct SoakTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_QUIC_SOAK"] == "1"))
    func sustainedMixedWorkload() async throws {
        let duration: Duration = .seconds(60)
        let connectionCount = 4
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let port = server.localAddress.port!
        let payload = makePatternedBuffer(byteCount: 64 * 1024)

        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                try await server.run { connection in
                    await withDiscardingTaskGroup { inner in
                        inner.addTask {
                            for await datagram in connection.datagrams {
                                try? await connection.sendDatagram(datagram)
                            }
                        }
                        await echoConnectionHandler(connection)
                    }
                }
                return 0
            }

            let deadline = ContinuousClock.now + duration
            for worker in 0..<connectionCount {
                group.addTask {
                    var iterations = 0
                    try await QUICClient.withConnection(
                        to: "127.0.0.1",
                        port: port,
                        configuration: configurations.client
                    ) { connection in
                        while ContinuousClock.now < deadline {
                            let stream = try await connection.openBidirectionalStream()
                            try await stream.send(payload)
                            try await stream.finish()
                            let reply = try await stream.collect(upTo: payload.readableBytes + 1)
                            guard reply == payload else {
                                throw QUICConnectionError(
                                    code: .closed,
                                    message: "soak worker \(worker): payload corrupted at iteration \(iterations)"
                                )
                            }
                            // Sprinkle datagrams in; they are unreliable, so
                            // only sending is asserted.
                            try await connection.sendDatagram(ByteBuffer(string: "soak-\(iterations)"))
                            iterations += 1
                        }
                    }
                    return iterations
                }
            }

            var totalIterations = 0
            for _ in 0..<connectionCount {
                totalIterations += try await group.next() ?? 0
            }
            print("soak: \(totalIterations) echo iterations across \(connectionCount) connections in \(duration)")
            #expect(totalIterations > 0)
            group.cancelAll()
        }
        await server.close()
    }
}
