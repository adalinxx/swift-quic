//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Loopback benchmarks for swift-quic. Run with:
//
//     SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift run -c release quic-bench
//
// All numbers are loopback (client and server in one process), so they
// measure the QUIC stack and this library's overhead, not a real network.

import Logging
import QUIC

func percentile(_ sorted: [Duration], _ p: Double) -> Duration {
    guard !sorted.isEmpty else { return .zero }
    let rank = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[rank]
}

func milliseconds(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.2f ms", seconds * 1000)
}

let alpn = ["quic-bench"]
let selfSigned = try QUICIdentity.selfSigned()
var serverConfiguration = QUICServer.Configuration(
    identity: selfSigned.identity,
    applicationProtocols: alpn
)
var quietLogger = Logger(label: "bench")
quietLogger.logLevel = .error
serverConfiguration.logger = quietLogger
serverConfiguration.transport.maxBidirectionalStreams = 512
serverConfiguration.transport.initialMaxData = 64 * 1024 * 1024

var clientConfiguration = QUICClient.Configuration(applicationProtocols: alpn)
clientConfiguration.trustRoots = .certificates([selfSigned.certificate])
clientConfiguration.logger = quietLogger
clientConfiguration.transport.maxBidirectionalStreams = 512
clientConfiguration.transport.initialMaxData = 64 * 1024 * 1024

let server = try await QUICServer.bind(host: "127.0.0.1", configuration: serverConfiguration)
let port = server.localAddress.port!
let clock = ContinuousClock()

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await server.run { connection in
            await withDiscardingTaskGroup { inner in
                inner.addTask {
                    for await datagram in connection.datagrams {
                        try? await connection.sendDatagram(datagram)
                    }
                }
                for await stream in connection.incomingStreams {
                    inner.addTask {
                        do {
                            for try await chunk in stream.inbound {
                                if stream.isWritable { try await stream.send(chunk) }
                            }
                            if stream.isWritable { try await stream.finish() }
                        } catch {}
                    }
                }
            }
        }
    }

    print("swift-quic loopback benchmarks")
    print("==============================")

    // 1. Handshake latency: full connect + first-stream round trip, serially.
    do {
        let iterations = 50
        var times: [Duration] = []
        for _ in 0..<iterations {
            let start = clock.now
            try await QUICClient.withConnection(
                to: "127.0.0.1", port: port, configuration: clientConfiguration
            ) { connection in
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("ping")
                try await stream.finish()
                _ = try await stream.collect(upTo: 64)
            }
            times.append(clock.now - start)
        }
        times.sort()
        print("connect + first round trip (n=\(iterations)):")
        print("  p50 \(milliseconds(percentile(times, 0.5)))  p90 \(milliseconds(percentile(times, 0.9)))  p99 \(milliseconds(percentile(times, 0.99)))")
    }

    // The remaining benchmarks share one connection.
    try await QUICClient.withConnection(
        to: "127.0.0.1", port: port, configuration: clientConfiguration
    ) { connection in
        // 2. Bulk throughput: echo a large payload (bytes cross loopback twice).
        do {
            let totalBytes = 64 * 1024 * 1024
            let payload = ByteBuffer(repeating: 0xA5, count: totalBytes)
            let stream = try await connection.openBidirectionalStream()
            let start = clock.now
            try await withThrowingTaskGroup(of: Void.self) { transfer in
                transfer.addTask {
                    var remaining = payload
                    while remaining.readableBytes > 0 {
                        let chunk = remaining.readSlice(length: min(256 * 1024, remaining.readableBytes))!
                        try await stream.send(chunk)
                    }
                    try await stream.finish()
                }
                transfer.addTask {
                    var received = 0
                    for try await chunk in stream.inbound {
                        received += chunk.readableBytes
                    }
                    precondition(received == totalBytes, "echo truncated: \(received)")
                }
                try await transfer.waitForAll()
            }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            // Echo means the data crossed the stack twice.
            let gbps = Double(totalBytes * 2) * 8 / seconds / 1e9
            print("bulk echo throughput (64 MiB): \(String(format: "%.2f", gbps)) Gbit/s (stack-crossings counted)")
        }

        // 3. Stream churn: sequential small request/response streams.
        do {
            let iterations = 500
            let start = clock.now
            for _ in 0..<iterations {
                let stream = try await connection.openBidirectionalStream()
                try await stream.send("r")
                try await stream.finish()
                _ = try await stream.collect(upTo: 64)
            }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("sequential streams: \(String(format: "%.0f", Double(iterations) / seconds)) streams/s")
        }

        // 4. Concurrent stream churn.
        do {
            let iterations = 500
            let width = 32
            let start = clock.now
            try await withThrowingTaskGroup(of: Void.self) { churn in
                var launched = 0
                var active = 0
                while launched < iterations {
                    while active < width && launched < iterations {
                        churn.addTask {
                            let stream = try await connection.openBidirectionalStream()
                            try await stream.send("r")
                            try await stream.finish()
                            _ = try await stream.collect(upTo: 64)
                        }
                        launched += 1
                        active += 1
                    }
                    try await churn.next()
                    active -= 1
                }
                try await churn.waitForAll()
            }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("concurrent streams (width 32): \(String(format: "%.0f", Double(iterations) / seconds)) streams/s")
        }

        // 5. Datagram round trips.
        do {
            let iterations = 2000
            let payload = ByteBuffer(repeating: 0x42, count: 1000)
            var received = 0
            let start = clock.now
            var iterator = connection.datagrams.makeAsyncIterator()
            for _ in 0..<iterations {
                try await connection.sendDatagram(payload)
                if await iterator.next() != nil {
                    received += 1
                }
            }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("datagram ping-pong (1000 B): \(String(format: "%.0f", Double(received) / seconds)) round trips/s (\(received)/\(iterations) delivered)")
        }
    }

    group.cancelAll()
}

await server.close()
