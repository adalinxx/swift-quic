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

/// A one-shot value box tests can await across the client/server boundary.
private actor ValueBox<Value: Sendable> {
    private var value: Value?
    func set(_ newValue: Value) { self.value = newValue }

    /// Waits until a value is set or the deadline passes; returns it (or nil).
    func waitForValue(within: Duration) async -> Value? {
        let deadline = ContinuousClock.now + within
        while self.value == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return self.value
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

    @Test
    func bidirectionalStreamEcho() async throws {
        // Server: for each incoming stream, read to EOF and echo it back.
        try await self.withServer { session in
            for await stream in session.incomingStreams {
                Task {
                    guard let payload = try? await stream.collect(upTo: 1 << 20) else { return }
                    try? await stream.send(payload)
                    await stream.finish()
                }
            }
        } _: { clientConfiguration, port in
            let session = try await WebTransportClient.connect(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            )
            let stream = try await session.openBidirectionalStream()
            #expect(!stream.isUnidirectional)
            #expect(stream.isLocallyInitiated)
            try await stream.send("hello webtransport streams")
            await stream.finish()
            let echoed = try await stream.collect(upTo: 1 << 20)
            #expect(String(buffer: echoed) == "hello webtransport streams")
            session.close()
        }
    }

    @Test
    func unidirectionalStreamDelivery() async throws {
        let received = ValueBox<String>()
        // Server: read the send-only stream the peer opened.
        try await self.withServer { session in
            for await stream in session.incomingStreams {
                #expect(stream.isUnidirectional)
                #expect(!stream.isLocallyInitiated)
                let received = received
                Task {
                    if let payload = try? await stream.collect(upTo: 1 << 20) {
                        await received.set(String(buffer: payload))
                    }
                }
            }
        } _: { clientConfiguration, port in
            let session = try await WebTransportClient.connect(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            )
            let stream = try await session.openUnidirectionalStream()
            #expect(stream.isUnidirectional)
            #expect(stream.isLocallyInitiated)
            try await stream.send("unidirectional payload")
            await stream.finish()
            let got = await received.waitForValue(within: .seconds(3))
            #expect(got == "unidirectional payload")
            session.close()
        }
    }

    @Test
    func multipleChunksOnOneStream() async throws {
        try await self.withServer { session in
            for await stream in session.incomingStreams {
                Task {
                    guard let payload = try? await stream.collect(upTo: 1 << 20) else { return }
                    try? await stream.send(payload)
                    await stream.finish()
                }
            }
        } _: { clientConfiguration, port in
            let session = try await WebTransportClient.connect(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            )
            let stream = try await session.openBidirectionalStream()
            for index in 0..<8 {
                try await stream.send("chunk-\(index);")
            }
            await stream.finish()
            let echoed = try await stream.collect(upTo: 1 << 20)
            let expected = (0..<8).map { "chunk-\($0);" }.joined()
            #expect(String(buffer: echoed) == expected)
            session.close()
        }
    }
}
