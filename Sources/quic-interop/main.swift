//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// QUIC Interop Runner endpoint (https://github.com/quic-interop/quic-interop-runner).
//
// Implements the `hq-interop` application protocol: the client opens one
// bidirectional stream per request, sends `GET /<file>\r\n` and a FIN; the
// server replies with the file's bytes and a FIN.
//
// Environment (per the runner's endpoint contract):
//   ROLE      "client" or "server"
//   TESTCASE  the test case to run; exit 127 if unsupported
//   REQUESTS  (client) space-separated URLs to fetch
//   Paths     /certs (server key material), /www (server files),
//             /downloads (client output) — overridable for local runs via
//             CERTS_DIR / WWW_DIR / DOWNLOADS_DIR / PORT / HOST.

import Foundation
import Logging
import QUIC
import X509

let environment = ProcessInfo.processInfo.environment
var logger = Logger(label: "quic-interop")
logger.logLevel = .info

let supportedTestcases: Set<String> = ["handshake", "transfer", "retry", "multiconnect"]
let testcase = environment["TESTCASE"] ?? "handshake"
guard supportedTestcases.contains(testcase) else {
    logger.info("unsupported testcase \(testcase)")
    exit(127)
}

let alpn = ["hq-interop"]
let role = environment["ROLE"] ?? "server"
let certsDirectory = environment["CERTS_DIR"] ?? "/certs"
let wwwDirectory = environment["WWW_DIR"] ?? "/www"
let downloadsDirectory = environment["DOWNLOADS_DIR"] ?? "/downloads"
let port = environment["PORT"].flatMap(Int.init) ?? 443

@Sendable
func parseRequest(_ buffer: ByteBuffer) -> String? {
    let text = String(buffer: buffer)
    guard text.hasPrefix("GET ") else { return nil }
    let path = text.dropFirst(4)
        .split(separator: "\r\n", maxSplits: 1)[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Prevent path escapes; the runner only uses flat file names.
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? nil : name
}

switch role {
case "gencert":
    // Local-testing convenience: write a fresh self-signed cert.pem/priv.key
    // into CERTS_DIR using this library's own generator.
    let generated = try QUICIdentity.selfSigned(
        commonName: "quic-interop",
        dnsNames: ["localhost", "server", "server4", "server6"],
        ipAddresses: ["127.0.0.1", "::1"]
    )
    try FileManager.default.createDirectory(
        atPath: certsDirectory, withIntermediateDirectories: true
    )
    try generated.certificate.serializeAsPEM().pemString
        .write(toFile: "\(certsDirectory)/cert.pem", atomically: true, encoding: .utf8)
    try generated.privateKey.serializeAsPEM().pemString
        .write(toFile: "\(certsDirectory)/priv.key", atomically: true, encoding: .utf8)
    logger.info("wrote cert.pem and priv.key to \(certsDirectory)")

case "server":
    var configuration = QUICServer.Configuration(
        identity: .certificateChain(
            pemFile: "\(certsDirectory)/cert.pem",
            privateKeyPEMFile: "\(certsDirectory)/priv.key"
        ),
        applicationProtocols: alpn
    )
    configuration.sendRetry = (testcase == "retry")
    configuration.transport.maxBidirectionalStreams = 512
    configuration.logger = logger

    let server = try await QUICServer.bind(host: "0.0.0.0", port: port, configuration: configuration)
    logger.info("hq-interop server listening on \(server.localAddress), testcase \(testcase)")

    try await server.run { connection in
        await withDiscardingTaskGroup { group in
            for await stream in connection.incomingStreams {
                group.addTask {
                    do {
                        let request = try await stream.collect(upTo: 4096)
                        guard let fileName = parseRequest(request) else {
                            stream.reset(errorCode: 1)
                            return
                        }
                        let url = URL(fileURLWithPath: wwwDirectory).appendingPathComponent(fileName)
                        let contents = try Data(contentsOf: url)
                        // Send in chunks to bound memory per stream.
                        var offset = 0
                        while offset < contents.count {
                            let end = min(offset + 256 * 1024, contents.count)
                            try await stream.send(ByteBuffer(bytes: contents[offset..<end]))
                            offset = end
                        }
                        try await stream.finish()
                    } catch {
                        stream.reset(errorCode: 1)
                    }
                }
            }
        }
    }

case "client":
    let requests = (environment["REQUESTS"] ?? "").split(separator: " ").map(String.init)
    guard !requests.isEmpty else {
        logger.error("client started with no REQUESTS")
        exit(1)
    }
    try FileManager.default.createDirectory(
        atPath: downloadsDirectory, withIntermediateDirectories: true
    )

    var configuration = QUICClient.Configuration(applicationProtocols: alpn)
    // The runner uses per-run self-signed certificates; it verifies file
    // integrity itself.
    configuration.certificateVerification = .none
    configuration.transport.maxBidirectionalStreams = 512
    configuration.logger = logger

    func fetch(_ request: String, over connection: QUICConnection) async throws {
        guard let url = URL(string: request), let host = url.host else {
            throw QUICConfigurationError("bad request URL: \(request)")
        }
        _ = host
        let fileName = url.lastPathComponent
        let stream = try await connection.openBidirectionalStream()
        try await stream.send("GET /\(fileName)\r\n")
        try await stream.finish()
        let contents = try await stream.collect(upTo: 1 << 30)
        let destination = URL(fileURLWithPath: downloadsDirectory).appendingPathComponent(fileName)
        try Data(contents.readableBytesView).write(to: destination)
        logger.info("downloaded \(fileName): \(contents.readableBytes) bytes")
    }

    guard let firstURL = URL(string: requests[0]), let host = firstURL.host else {
        logger.error("bad request URL: \(requests[0])")
        exit(1)
    }
    let targetPort = firstURL.port ?? 443

    if testcase == "multiconnect" {
        for request in requests {
            try await QUICClient.withConnection(
                to: host, port: targetPort, configuration: configuration
            ) { connection in
                try await fetch(request, over: connection)
            }
        }
    } else {
        try await QUICClient.withConnection(
            to: host, port: targetPort, configuration: configuration
        ) { connection in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask { try await fetch(request, over: connection) }
                }
                try await group.waitForAll()
            }
        }
    }
    logger.info("client finished: \(requests.count) request(s)")

default:
    logger.error("unknown ROLE \(role)")
    exit(1)
}
