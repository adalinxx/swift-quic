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

/// A deterministic PRNG so lossy-network tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double(self.next() >> 11) * (1.0 / 9_007_199_254_740_992.0) < probability
    }
}

/// A UDP proxy that forwards datagrams between a client and a server while
/// randomly dropping, reordering, and duplicating packets. QUIC's loss
/// recovery must transparently repair everything the proxy mangles.
final class LossyUDPProxy {
    struct Impairments: Sendable {
        var dropProbability: Double
        var reorderProbability: Double
        var duplicateProbability: Double
        var seed: UInt64
    }

    private let channel: any Channel

    var localAddress: SocketAddress {
        self.channel.localAddress!
    }

    init(serverAddress: SocketAddress, impairments: Impairments) async throws {
        self.channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        Handler(serverAddress: serverAddress, impairments: impairments)
                    )
                    return channel
                }
            }
    }

    func close() async {
        try? await self.channel.close().get()
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        private let serverAddress: SocketAddress
        private var clientAddress: SocketAddress?
        private var rng: SplitMix64
        private let impairments: Impairments
        /// One packet per direction can be held back to swap its order with
        /// the next one.
        private var heldToServer: ByteBuffer?
        private var heldToClient: ByteBuffer?

        init(serverAddress: SocketAddress, impairments: Impairments) {
            self.serverAddress = serverAddress
            self.impairments = impairments
            self.rng = SplitMix64(seed: impairments.seed)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = self.unwrapInboundIn(data)
            let towardsServer: Bool
            if envelope.remoteAddress == self.serverAddress {
                towardsServer = false
            } else {
                self.clientAddress = envelope.remoteAddress
                towardsServer = true
            }

            if self.rng.chance(self.impairments.dropProbability) {
                return
            }

            var toSend: [ByteBuffer] = []
            if self.rng.chance(self.impairments.reorderProbability) {
                // Hold this packet; it goes out after the next one.
                if towardsServer {
                    if let previouslyHeld = self.heldToServer {
                        toSend.append(previouslyHeld)
                    }
                    self.heldToServer = envelope.data
                } else {
                    if let previouslyHeld = self.heldToClient {
                        toSend.append(previouslyHeld)
                    }
                    self.heldToClient = envelope.data
                }
            } else {
                toSend.append(envelope.data)
                if towardsServer, let held = self.heldToServer {
                    toSend.append(held)
                    self.heldToServer = nil
                } else if !towardsServer, let held = self.heldToClient {
                    toSend.append(held)
                    self.heldToClient = nil
                }
            }

            if self.rng.chance(self.impairments.duplicateProbability), let first = toSend.first {
                toSend.append(first)
            }

            guard let target = towardsServer ? self.serverAddress : self.clientAddress else {
                return
            }
            for buffer in toSend {
                context.write(
                    self.wrapOutboundOut(AddressedEnvelope(remoteAddress: target, data: buffer)),
                    promise: nil
                )
            }
            context.flush()
        }
    }
}

@Suite(.timeLimit(.minutes(2)))
struct LossyNetworkTests {
    private func runEchoThroughProxy(
        impairments: LossyUDPProxy.Impairments,
        payloadBytes: Int
    ) async throws {
        let configurations = try TestConfigurations()
        let server = try await QUICServer.bind(host: "127.0.0.1", configuration: configurations.server)
        let proxy = try await LossyUDPProxy(
            serverAddress: server.localAddress,
            impairments: impairments
        )
        let proxyPort = proxy.localAddress.port!

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run { connection in
                    await echoConnectionHandler(connection)
                }
            }

            let payload = makePatternedBuffer(byteCount: payloadBytes)
            try await QUICClient.withConnection(
                to: "127.0.0.1",
                port: proxyPort,
                configuration: configurations.client
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                try await withThrowingTaskGroup(of: Void.self) { transfer in
                    transfer.addTask {
                        var remaining = payload
                        while remaining.readableBytes > 0 {
                            let chunk = remaining.readSlice(
                                length: min(16 * 1024, remaining.readableBytes)
                            )!
                            try await stream.send(chunk)
                        }
                        try await stream.finish()
                    }
                    transfer.addTask {
                        let reply = try await stream.collect(upTo: payload.readableBytes + 1)
                        #expect(reply == payload)
                    }
                    try await transfer.waitForAll()
                }
            }

            group.cancelAll()
        }
        await proxy.close()
        await server.close()
    }

    @Test
    func echoSurvivesTenPercentLoss() async throws {
        try await self.runEchoThroughProxy(
            impairments: .init(
                dropProbability: 0.10,
                reorderProbability: 0,
                duplicateProbability: 0,
                seed: 42
            ),
            payloadBytes: 64 * 1024
        )
    }

    @Test
    func transferSurvivesLossReorderingAndDuplication() async throws {
        try await self.runEchoThroughProxy(
            impairments: .init(
                dropProbability: 0.05,
                reorderProbability: 0.10,
                duplicateProbability: 0.05,
                seed: 7
            ),
            payloadBytes: 512 * 1024
        )
    }

    @Test
    func handshakeSurvivesLossyFirstFlight() async throws {
        // A high drop rate stresses handshake retransmission specifically.
        try await self.runEchoThroughProxy(
            impairments: .init(
                dropProbability: 0.20,
                reorderProbability: 0.05,
                duplicateProbability: 0,
                seed: 1234
            ),
            payloadBytes: 1024
        )
    }
}
