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
import HTTPTypes
import QUIC
import QUICHTTP3
import Testing

/// Real-world HTTP/3 interop against production servers. Disabled by default
/// (needs outbound internet and is not hermetic); enable with
/// `SWIFT_QUIC_PUBLIC_INTEROP=1 swift test --filter HTTP3PublicInteropTests`.
@Suite(.timeLimit(.minutes(2)))
struct HTTP3PublicInteropTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_QUIC_PUBLIC_INTEROP"] == "1"))
    func getFromCloudflare() async throws {
        // cloudflare-quic.com is a well-known HTTP/3 test endpoint using
        // publicly-trusted certificates, so we verify against the system store.
        let response = try await HTTP3Client.withConnection(
            to: "cloudflare-quic.com",
            port: 443,
            configuration: HTTP3Client.Configuration()
        ) { connection in
            try await connection.get("/", headerFields: [HTTPField.Name("user-agent")!: "swift-quic"])
        }
        #expect(response.status == .ok)
        #expect(response.body.readableBytes > 0)
        print("cloudflare-quic.com returned \(response.status) with \(response.body.readableBytes) bytes over HTTP/3")
    }
}
