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
struct HTTP3EndToEndTests {
    /// Starts an HTTP/3 server with the given handler, runs `body` with a
    /// matched client configuration and the server port, then tears down.
    private func withHTTP3Server(
        handler: @escaping @Sendable (HTTP3ServerRequest) async -> HTTP3Response,
        _ body: @escaping @Sendable (HTTP3Client.Configuration, Int) async throws -> Void
    ) async throws {
        let selfSigned = try QUICIdentity.selfSigned(
            commonName: "h3-test",
            dnsNames: ["localhost"],
            ipAddresses: ["127.0.0.1", "::1"]
        )
        var serverConfiguration = HTTP3Server.Configuration(identity: selfSigned.identity)
        var quietServer = Logger(label: "h3-server")
        quietServer.logLevel = .critical
        serverConfiguration.logger = quietServer

        let server = try await HTTP3Server.bind(host: "127.0.0.1", configuration: serverConfiguration)
        let port = server.localAddress.port!

        var clientConfiguration = HTTP3Client.Configuration()
        clientConfiguration.trustRoots = .certificates([selfSigned.certificate])
        var quietClient = Logger(label: "h3-client")
        quietClient.logLevel = .critical
        clientConfiguration.logger = quietClient

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run(handler)
            }
            try await body(clientConfiguration, port)
            group.cancelAll()
        }
        await server.close()
    }

    @Test
    func getRequestResponse() async throws {
        try await self.withHTTP3Server { request in
            HTTP3Response(
                status: .ok,
                headerFields: [.contentType: "text/plain"],
                string: "you asked for \(request.path)"
            )
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let response = try await connection.get("/hello")
                #expect(response.status == .ok)
                #expect(response.headerFields[.contentType] == "text/plain")
                #expect(String(buffer: response.body) == "you asked for /hello")
            }
        }
    }

    @Test
    func postEchoesBody() async throws {
        try await self.withHTTP3Server { request in
            HTTP3Response(status: .created, body: request.body)
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let payload = "the quick brown fox"
                let response = try await connection.request(
                    HTTP3Request(method: .post, path: "/echo", body: ByteBuffer(string: payload))
                )
                #expect(response.status == .created)
                #expect(String(buffer: response.body) == payload)
            }
        }
    }

    @Test
    func multipleSequentialRequestsOnOneConnection() async throws {
        try await self.withHTTP3Server { request in
            HTTP3Response(status: .ok, string: request.path)
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                for index in 0..<5 {
                    let response = try await connection.get("/item/\(index)")
                    #expect(response.status == .ok)
                    #expect(String(buffer: response.body) == "/item/\(index)")
                }
            }
        }
    }

    @Test
    func largeResponseBody() async throws {
        // 4 MiB response exercises DATA-frame chunking across the request stream.
        let bodyBytes = 4 * 1024 * 1024
        try await self.withHTTP3Server { _ in
            HTTP3Response(status: .ok, body: ByteBuffer(repeating: 0x7A, count: bodyBytes))
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let response = try await connection.get("/big")
                #expect(response.status == .ok)
                #expect(response.body.readableBytes == bodyBytes)
            }
        }
    }

    @Test
    func statusAndHeadersPropagate() async throws {
        try await self.withHTTP3Server { _ in
            HTTP3Response(status: .notFound, headerFields: [HTTPField.Name("x-reason")!: "missing"])
        } _: { clientConfiguration, port in
            try await HTTP3Client.withConnection(
                to: "127.0.0.1",
                port: port,
                configuration: clientConfiguration
            ) { connection in
                let response = try await connection.get("/missing")
                #expect(response.status == .notFound)
                #expect(response.headerFields[HTTPField.Name("x-reason")!] == "missing")
            }
        }
    }
}
