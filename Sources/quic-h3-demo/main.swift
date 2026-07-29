//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// A self-contained HTTP/3 demo: starts an HTTP/3 server with an ephemeral
// self-signed certificate, then makes a GET and a POST from an HTTP/3 client.
//
// Run with: swift run quic-h3-demo

import HTTPTypes
import Logging
import QUIC
import QUICHTTP3

let selfSigned = try QUICIdentity.selfSigned()

var serverConfiguration = HTTP3Server.Configuration(identity: selfSigned.identity)
serverConfiguration.logger = { var l = Logger(label: "h3-server"); l.logLevel = .error; return l }()

let server = try await HTTP3Server.bind(host: "127.0.0.1", configuration: serverConfiguration)
print("HTTP/3 server listening on \(server.localAddress)")

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await server.run { request in
            switch request.method {
            case .post:
                return HTTP3Response(status: .created, body: request.body)
            default:
                return HTTP3Response(status: .ok, string: "Hello over HTTP/3! You requested \(request.path)")
            }
        }
    }

    var clientConfiguration = HTTP3Client.Configuration()
    clientConfiguration.trustRoots = .certificates([selfSigned.certificate])
    clientConfiguration.logger = { var l = Logger(label: "h3-client"); l.logLevel = .error; return l }()

    try await HTTP3Client.withConnection(
        to: "127.0.0.1",
        port: server.localAddress.port!,
        configuration: clientConfiguration
    ) { connection in
        let get = try await connection.get("/index.html")
        print("GET  -> \(get.status): \(String(buffer: get.body))")

        let post = try await connection.request(
            HTTP3Request(method: .post, path: "/upload", body: ByteBuffer(string: "payload bytes"))
        )
        print("POST -> \(post.status): \(String(buffer: post.body))")
    }

    group.cancelAll()
}

await server.close()
print("done")
