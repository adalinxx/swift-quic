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
struct HTTP3TrailersTests {
    private func withServer(
        collected handler: @escaping @Sendable (HTTP3ServerRequest) async -> HTTP3Response,
        _ body: @escaping @Sendable (HTTP3Client.Configuration, Int) async throws -> Void
    ) async throws {
        let selfSigned = try QUICIdentity.selfSigned(dnsNames: ["localhost"], ipAddresses: ["127.0.0.1", "::1"])
        var serverConfiguration = HTTP3Server.Configuration(identity: selfSigned.identity)
        var quiet = Logger(label: "s"); quiet.logLevel = .critical
        serverConfiguration.logger = quiet
        let server = try await HTTP3Server.bind(host: "127.0.0.1", configuration: serverConfiguration)
        let port = server.localAddress.port!
        var clientConfiguration = HTTP3Client.Configuration()
        clientConfiguration.trustRoots = .certificates([selfSigned.certificate])
        var quietC = Logger(label: "c"); quietC.logLevel = .critical
        clientConfiguration.logger = quietC
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run(handler) }
            try await body(clientConfiguration, port)
            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func collectedResponseTrailersRoundTrip() async throws {
        let checksum = HTTPField.Name("x-checksum")!
        try await self.withServer { _ in
            HTTP3Response(
                status: .ok,
                body: ByteBuffer(string: "payload"),
                trailers: [checksum: "abc123"]
            )
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(to: "127.0.0.1", port: port, configuration: clientConfiguration) {
                connection in
                let response = try await connection.get("/")
                #expect(String(buffer: response.body) == "payload")
                #expect(response.trailers[checksum] == "abc123")
            }
        }
    }

    @Test
    func streamingResponseTrailers() async throws {
        let count = HTTPField.Name("x-chunk-count")!
        let selfSigned = try QUICIdentity.selfSigned(dnsNames: ["localhost"], ipAddresses: ["127.0.0.1", "::1"])
        var serverConfiguration = HTTP3Server.Configuration(identity: selfSigned.identity)
        var quiet = Logger(label: "s"); quiet.logLevel = .critical
        serverConfiguration.logger = quiet
        let server = try await HTTP3Server.bind(host: "127.0.0.1", configuration: serverConfiguration)
        let port = server.localAddress.port!
        var clientConfiguration = HTTP3Client.Configuration()
        clientConfiguration.trustRoots = .certificates([selfSigned.certificate])
        var quietC = Logger(label: "c"); quietC.logLevel = .critical
        clientConfiguration.logger = quietC

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run(streaming: { _, response in
                    try await response.writeHead(status: .ok)
                    try await response.write("a")
                    try await response.write("b")
                    response.setTrailers([count: "2"])
                })
            }
            try await HTTP3Client.withConnection(to: "127.0.0.1", port: port, configuration: clientConfiguration) {
                connection in
                try await connection.withStreamingRequest(
                    HTTPRequest(method: .get, scheme: "https", authority: "test", path: "/")
                ) { writer, response in
                    writer.finish()
                    _ = try await response.head()
                    var total = 0
                    for try await chunk in response.body { total += chunk.readableBytes }
                    #expect(total == 2)
                    // Trailers are available once the body is fully consumed.
                    #expect(response.body.trailers?[count] == "2")
                }
            }
            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func requestTrailersReceivedByServer() async throws {
        let marker = HTTPField.Name("x-request-trailer")!
        try await self.withServer { request in
            HTTP3Response(status: .ok, string: request.trailers[marker] ?? "none")
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(to: "127.0.0.1", port: port, configuration: clientConfiguration) {
                connection in
                let echoed = try await connection.withStreamingRequest(
                    HTTPRequest(method: .post, scheme: "https", authority: "test", path: "/")
                ) { writer, response -> String in
                    try await writer.write("body")
                    try await writer.finish(trailers: [marker: "present"])
                    _ = try await response.head()
                    var collected = ByteBuffer()
                    for try await chunk in response.body {
                        var chunk = chunk
                        collected.writeBuffer(&chunk)
                    }
                    return String(buffer: collected)
                }
                #expect(echoed == "present")
            }
        }
    }
}
