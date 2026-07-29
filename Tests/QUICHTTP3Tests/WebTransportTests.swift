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
import QUICHTTP3
import Testing

/// Collects a session's datagrams off a background task so tests can poll
/// without sharing the (non-Sendable) async iterator.
private actor DatagramCollector {
    private(set) var items: [ByteBuffer] = []
    func append(_ buffer: ByteBuffer) { self.items.append(buffer) }
    var count: Int { self.items.count }

    /// Waits until at least `target` datagrams have arrived or the deadline
    /// passes; returns the count reached.
    func waitForCount(_ target: Int, within: Duration) async -> Int {
        let deadline = ContinuousClock.now + within
        while self.items.count < target, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return self.items.count
    }
}

@Suite(.timeLimit(.minutes(2)))
struct WebTransportTests {
    private func withServer(
        handler: @escaping @Sendable (WebTransportSession) async -> Void,
        _ body: @escaping @Sendable (WebTransportClient.Configuration, Int) async throws -> Void
    ) async throws {
        let selfSigned = try QUICIdentity.selfSigned(
            commonName: "webtransport-test",
            dnsNames: ["localhost"],
            ipAddresses: ["127.0.0.1", "::1"]
        )
        var serverConfiguration = WebTransportServer.Configuration(identity: selfSigned.identity)
        var quiet = Logger(label: "wt-server"); quiet.logLevel = .critical
        serverConfiguration.logger = quiet
        let server = try await WebTransportServer.bind(host: "127.0.0.1", configuration: serverConfiguration)
        let port = server.localAddress.port!

        var clientConfiguration = WebTransportClient.Configuration()
        clientConfiguration.trustRoots = .certificates([selfSigned.certificate])
        var quietC = Logger(label: "wt-client"); quietC.logLevel = .critical
        clientConfiguration.logger = quietC

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await server.run(handler) }
            try await body(clientConfiguration, port)
            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func establishesSession() async throws {
        try await self.withServer { session in
            for await _ in session.datagrams {}
        } _: { clientConfiguration, port in
            let session = try await WebTransportClient.connect(
                to: "127.0.0.1",
                port: port,
                path: "/wt",
                configuration: clientConfiguration
            )
            #expect(session.request.method == .connect)
            #expect(session.request.extendedConnectProtocol == "webtransport")
            #expect(!session.isClosed)
            session.close()
            #expect(session.isClosed)
        }
    }

    @Test
    func datagramEchoRoundTrip() async throws {
        try await self.withServer { session in
            for await datagram in session.datagrams {
                session.sendDatagram(datagram)
            }
        } _: { clientConfiguration, port in
            let session = try await WebTransportClient.connect(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            )
            let collector = DatagramCollector()
            let session2 = session
            Task { for await d in session2.datagrams { await collector.append(d) } }

            // Send until an echo comes back: the peer's session registration
            // can race the first datagram (both are unreliable).
            let payload = ByteBuffer(string: "hello webtransport")
            var received = 0
            for _ in 0..<20 where received == 0 {
                session.sendDatagram(payload)
                received = await collector.waitForCount(1, within: .milliseconds(150))
            }
            #expect(received >= 1)
            #expect(await collector.items.first == payload)
            session.close()
        }
    }

    @Test
    func manyDatagrams() async throws {
        try await self.withServer { session in
            for await datagram in session.datagrams {
                session.sendDatagram(datagram)
            }
        } _: { clientConfiguration, port in
            let session = try await WebTransportClient.connect(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            )
            let collector = DatagramCollector()
            let session2 = session
            Task { for await d in session2.datagrams { await collector.append(d) } }

            // Warm up the echo path.
            var warm = 0
            for _ in 0..<20 where warm == 0 {
                session.sendDatagram(ByteBuffer(string: "warmup"))
                warm = await collector.waitForCount(1, within: .milliseconds(150))
            }
            #expect(warm >= 1)

            let baseline = await collector.count
            for index in 0..<10 {
                session.sendDatagram(ByteBuffer(string: "msg-\(index)"))
            }
            let total = await collector.waitForCount(baseline + 10, within: .seconds(2))
            // Unreliable, but loopback should deliver most.
            #expect(total - baseline >= 5)
            session.close()
        }
    }
}
