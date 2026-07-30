# swift-quic

[![CI](https://github.com/adalinxx/swift-quic/actions/workflows/ci.yml/badge.svg)](https://github.com/adalinxx/swift-quic/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-DocC-blue)](https://adalinxx.github.io/swift-quic/documentation/quic/)
[![License](https://img.shields.io/badge/license-Apache--2.0-lightgrey)](LICENSE.txt)

An easy-to-use, fully-tested Swift QUIC library built on Apple's
[swift-nio-quic](https://github.com/apple/swift-nio-quic).

`swift-quic` wraps the low-level NIO channel machinery in a small, modern Swift
API: `async`/`await` everywhere, `AsyncSequence` for streams and datagrams,
structured-concurrency-friendly lifecycles, and safe defaults (full certificate
verification, sensible transport parameters).

## Features

- **HTTP/3** (RFC 9114): an `HTTP3Server` / `HTTP3Client` layer (the `QUICHTTP3`
  product) with async request/response over
  [swift-nio-http3](https://github.com/apple/swift-nio-http3), including
  **incremental streaming bodies** in both directions (uploads, downloads,
  SSE-style responses) and **trailer fields**. Verified against production
  servers (fetches `cloudflare-quic.com` over HTTP/3).
- **WebTransport** (draft-ietf-webtrans-http3): `WebTransportServer` /
  `WebTransportClient` with sessions over HTTP/3 extended CONNECT, datagrams,
  and bidirectional/unidirectional streams, end-to-end tested.
- **Streams**: bidirectional and unidirectional, client- and server-initiated,
  with flow-control-aware backpressure on reads and writes.
- **Unreliable datagrams** (RFC 9221): `sendDatagram(_:)` and an async
  `datagrams` sequence, with bounded drop-oldest receive buffering.
- **Stream lifecycle control**: half-close (`finish()`), `RESET_STREAM`
  (`reset(errorCode:)`), `STOP_SENDING` (`stopSending(errorCode:)`), and typed
  errors carrying the peer's application error codes.
- **TLS made simple**: PEM files, in-memory certificates, raw public keys
  (RFC 7250), custom trust roots, and a one-line ephemeral **self-signed
  identity** for development.
- **Post-quantum key exchange**: opt into hybrid `X25519MLKEM768` with one
  setting.
- **Graceful shutdown**, application-error connection close, keep-alive,
  Retry-based address validation, qlog and `SSLKEYLOGFILE` configuration
  hooks, and swift-metrics integration.

## Requirements

- Swift 6.3
- macOS 26+ (or other 26-era Apple platforms) **or Linux** (tested in
  `swift:6.3` containers; both run the full test suite in CI)
- Build with `SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1` while the
  dependency tree uses a swift-crypto beta

## Quick start

```swift
dependencies: [
    .package(url: "https://github.com/adalinxx/swift-quic", from: "0.2.0"),
]
// target dependencies: .product(name: "QUIC", package: "swift-quic")
```

### Server

```swift
import QUIC

let server = try await QUICServer.bind(
    host: "0.0.0.0",
    port: 4433,
    configuration: .init(
        identity: .certificateChain(pemFile: "cert.pem", privateKeyPEMFile: "key.pem"),
        applicationProtocols: ["my-proto"]
    )
)

try await server.run { connection in
    for await stream in connection.incomingStreams {
        // Echo:
        for try await chunk in stream.inbound {
            try await stream.send(chunk)
        }
        try await stream.finish()
    }
}
```

### Client

```swift
import QUIC

var configuration = QUICClient.Configuration(applicationProtocols: ["my-proto"])

try await QUICClient.withConnection(to: "example.com", port: 4433, configuration: configuration) { connection in
    let stream = try await connection.openBidirectionalStream()
    try await stream.send("hello")
    try await stream.finish()
    let reply = try await stream.collect(upTo: 1 << 20)
    print(String(buffer: reply))
}
```

### Datagrams

```swift
try await connection.sendDatagram(ByteBuffer(string: "unreliable ping"))
for await datagram in connection.datagrams {
    print("got \(datagram.readableBytes) bytes")
}
```

### HTTP/3

Add the `QUICHTTP3` product alongside `QUIC`, then:

```swift
import QUICHTTP3

// Server
let server = try await HTTP3Server.bind(
    host: "0.0.0.0", port: 443,
    configuration: .init(identity: .certificateChain(pemFile: "cert.pem", privateKeyPEMFile: "key.pem"))
)
try await server.run { request in
    HTTP3Response(status: .ok, string: "you requested \(request.path)")
}

// Client
try await HTTP3Client.withConnection(to: "example.com", port: 443, configuration: .init()) { connection in
    let response = try await connection.get("/")
    print(response.status, String(buffer: response.body))
}
```

For large or long-lived bodies, stream incrementally instead of buffering:

```swift
// Server: echo the request body back without collecting it
try await server.run(streaming: { request, response in
    try await response.writeHead(status: .ok)
    for try await chunk in request.body { try await response.write(chunk) }
})

// Client: stream a request body, then read the response body incrementally
try await connection.withStreamingRequest(HTTPRequest(method: .post, scheme: "https", authority: "h", path: "/")) { writer, response in
    try await writer.write(ByteBuffer(string: "chunk")); writer.finish()
    let head = try await response.head()
    for try await chunk in response.body { /* ... */ }
}
```

Run the demo with `swift run quic-h3-demo`.

### WebTransport

WebTransport (draft-ietf-webtrans-http3) runs over HTTP/3 extended CONNECT and
offers unreliable datagrams plus reliable bidirectional/unidirectional streams,
all multiplexed on one session. It ships in the `QUICHTTP3` product.

```swift
import QUICHTTP3

// Server: accept sessions; echo datagrams and each incoming stream.
let server = try await WebTransportServer.bind(
    host: "0.0.0.0", port: 443,
    configuration: .init(identity: .certificateChain(pemFile: "cert.pem", privateKeyPEMFile: "key.pem"))
)
try await server.run { session in
    Task { for await datagram in session.datagrams { session.sendDatagram(datagram) } }
    for await stream in session.incomingStreams {
        Task {
            let payload = try? await stream.collect(upTo: 1 << 20)
            if let payload { try? await stream.send(payload) }
            await stream.finish()
        }
    }
}

// Client: open a session, then a bidirectional stream.
let session = try await WebTransportClient.connect(to: "example.com", port: 443, path: "/wt")
session.sendDatagram("unreliable ping")

let stream = try await session.openBidirectionalStream()
try await stream.send("hello over a stream")
await stream.finish()
print(String(buffer: try await stream.collect(upTo: 1 << 20)))
session.close()
```

### Development TLS in one line

```swift
let selfSigned = try QUICIdentity.selfSigned()          // in-memory, ephemeral
// server:
let serverConfig = QUICServer.Configuration(
    identity: selfSigned.identity, applicationProtocols: ["dev"])
// client:
var clientConfig = QUICClient.Configuration(applicationProtocols: ["dev"])
clientConfig.trustRoots = .certificates([selfSigned.certificate])
```

### Demo

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift run quic-echo
```

## Testing

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift test
```

The suite (56 tests, run on macOS and Linux in CI) includes unit tests for
the configuration surface plus end-to-end integration tests over loopback
UDP: stream echoes, concurrent streams and connections, 8 MiB
flow-control-crossing transfers, half-close, `RESET_STREAM`/`STOP_SENDING`
semantics, datagram round trips and error cases, TLS trust failures, ALPN
mismatch, post-quantum key exchange, and graceful shutdown — plus
**adverse-network tests** that push traffic through a seeded UDP proxy
injecting 5–20% loss, reordering, and duplication. A 60-second soak test runs
nightly.

## Production use

See [docs/production-guide.md](docs/production-guide.md) for a candid
readiness statement, configuration checklist (TLS, timeouts, flow control,
address validation), and operational practices.

## Benchmarks, interop, roadmap

- [BENCHMARKS.md](BENCHMARKS.md) — loopback numbers and how to reproduce them
  (`swift run -c release quic-bench`).
- [interop/](interop/) — a [QUIC Interop Runner](https://github.com/quic-interop/quic-interop-runner)
  endpoint speaking `hq-interop`, with hash-verified transfers against
  quic-go and quiche.
- [ROADMAP.md](ROADMAP.md) — an honest map of what's done, what's next, and
  what's blocked on the upstream stack (0-RTT, migration, BBR, mTLS, semver
  releases).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## Architecture

```
┌────────────────────────────────────────────────┐
│  QUIC (this library)                           │
│  QUICServer / QUICClient / QUICConnection /    │
│  QUICStream — async/await, AsyncSequence       │
├────────────────────────────────────────────────┤
│  NIOQUIC (apple/swift-nio-quic)                │
│  Channel pipeline bindings, multiplexing       │
├────────────────────────────────────────────────┤
│  SwiftNetwork QUIC (swift-network-evolution)   │
│  + SwiftTLS — protocol implementation          │
└────────────────────────────────────────────────┘
```

## License

Apache 2.0
