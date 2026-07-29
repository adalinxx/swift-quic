//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import Logging
import NIOCore
import QUIC
import QUICHTTP3
import Testing

@Suite(.timeLimit(.minutes(2)))
struct HTTP3StreamingTests {
    private func withStreamingServer(
        handler: @escaping @Sendable (HTTP3Server.StreamingRequest, HTTP3Server.ResponseWriter) async throws -> Void,
        _ body: @escaping @Sendable (HTTP3Client.Configuration, Int) async throws -> Void
    ) async throws {
        let selfSigned = try QUICIdentity.selfSigned(
            commonName: "h3-stream-test",
            dnsNames: ["localhost"],
            ipAddresses: ["127.0.0.1", "::1"]
        )
        var serverConfiguration = HTTP3Server.Configuration(identity: selfSigned.identity)
        var quiet = Logger(label: "h3-stream-server")
        quiet.logLevel = .critical
        serverConfiguration.logger = quiet

        let server = try await HTTP3Server.bind(host: "127.0.0.1", configuration: serverConfiguration)
        let port = server.localAddress.port!

        var clientConfiguration = HTTP3Client.Configuration()
        clientConfiguration.trustRoots = .certificates([selfSigned.certificate])
        var quietC = Logger(label: "h3-stream-client")
        quietC.logLevel = .critical
        clientConfiguration.logger = quietC

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run(streaming: handler) }
            try await body(clientConfiguration, port)
            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func streamingEchoInBothDirections() async throws {
        // Server echoes each inbound chunk straight back out without collecting
        // the whole body first.
        try await self.withStreamingServer { request, response in
            try await response.writeHead(status: .ok)
            for try await chunk in request.body {
                try await response.write(chunk)
            }
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let chunkCount = 16
                let chunk = ByteBuffer(repeating: 0x51, count: 64 * 1024)

                try await connection.withStreamingRequest(
                    HTTPRequest(method: .post, scheme: "https", authority: "test", path: "/echo")
                ) { writer, response in
                    let head = try await response.head()
                    #expect(head.status == .ok)

                    // Interleave sending and receiving so nothing buffers the
                    // whole body: send a chunk, read a chunk.
                    var received = 0
                    var bodyIterator = response.body.makeAsyncIterator()
                    for _ in 0..<chunkCount {
                        try await writer.write(chunk)
                        let echoed = try await bodyIterator.next()
                        received += echoed?.readableBytes ?? 0
                    }
                    writer.finish()
                    while let tail = try await bodyIterator.next() {
                        received += tail.readableBytes
                    }
                    #expect(received == chunkCount * chunk.readableBytes)
                }
            }
        }
    }

    @Test
    func streamingResponseDownload() async throws {
        // Server produces a large response body in many writes; client reads it
        // incrementally.
        let chunkCount = 64
        let chunkSize = 32 * 1024
        try await self.withStreamingServer { _, response in
            try await response.writeHead(status: .ok)
            let chunk = ByteBuffer(repeating: 0x2A, count: chunkSize)
            for _ in 0..<chunkCount {
                try await response.write(chunk)
            }
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                try await connection.withStreamingRequest(
                    HTTPRequest(method: .get, scheme: "https", authority: "test", path: "/big")
                ) { writer, response in
                    writer.finish()
                    let head = try await response.head()
                    #expect(head.status == .ok)
                    var total = 0
                    var chunks = 0
                    for try await piece in response.body {
                        total += piece.readableBytes
                        chunks += 1
                    }
                    #expect(total == chunkCount * chunkSize)
                    #expect(chunks > 1)  // genuinely arrived in multiple pieces
                }
            }
        }
    }

    @Test
    func streamingUploadCollectedByServer() async throws {
        // Client streams a request body; server reads it incrementally and
        // reports the total it received.
        try await self.withStreamingServer { request, response in
            var total = 0
            for try await chunk in request.body {
                total += chunk.readableBytes
            }
            try await response.writeHead(status: .ok)
            try await response.write("received \(total)")
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let uploadChunks = 20
                let chunkSize = 48 * 1024
                let responseText = try await connection.withStreamingRequest(
                    HTTPRequest(method: .post, scheme: "https", authority: "test", path: "/upload")
                ) { writer, response -> String in
                    for _ in 0..<uploadChunks {
                        try await writer.write(ByteBuffer(repeating: 0x7E, count: chunkSize))
                    }
                    writer.finish()
                    var collected = ByteBuffer()
                    for try await piece in response.body {
                        var piece = piece
                        collected.writeBuffer(&piece)
                    }
                    return String(buffer: collected)
                }
                #expect(responseText == "received \(uploadChunks * chunkSize)")
            }
        }
    }
}
