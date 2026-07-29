# Changelog

## Unreleased

- **WebTransport foundation**: RFC 9297 HTTP/3 datagram and capsule wire
  codecs plus RFC 9000 QUIC variable-length integers (`HTTP3DatagramCodec`,
  `QUICVarint`), with 9 unit tests including the RFC 9000 § A.1 known-answer
  vector. This is the framing layer WebTransport (and MASQUE) build on;
  connection-channel datagram routing and extended-CONNECT session lifecycle
  are the remaining pieces (ROADMAP.md, docs/upstream-issues/04).

## 0.6.0 — 2026-07-29

- **Datagram receive batching (`recvmmsg`)**, now correct: all UDP sockets
  enable NIO vectored datagram reads paired with a
  `FixedSizeRecvByteBufferAllocator` sized so each of the 8 message slots holds
  a full datagram (2 KiB — matching NIO's own datagram default). This is the
  fix for the truncation that broke Linux in 0.5.0's reverted attempt: the
  earlier try enabled the option without sizing the receive buffer, so every
  packet was truncated on Linux. Verified across repeated Linux runs. No-op on
  Darwin (no `recvmmsg`), where servers rarely run anyway.
- Hardened one intermittently-flaky integration test against the upstream
  TLS-teardown race (docs/upstream-issues/03) with a bounded connection retry.

## 0.5.0 — 2026-07-29

- **HTTP/3 trailers**: send and receive trailer fields on both the collected
  and streaming APIs — `HTTP3Response.trailers`, `HTTP3ServerRequest.trailers`,
  `ResponseWriter.setTrailers(_:)`, `RequestBodyWriter.finish(trailers:)`, and
  `HTTP3IncomingBody.trailers` (available once the body is consumed). Tested for
  collected responses, streaming responses, and request trailers.
- **Datagram receive batching (`recvmmsg`)** was attempted and **reverted**:
  it measured neutral on loopback and broke the Linux datagram path (caught by
  Linux CI). Needs deeper NIOQUIC integration — see BENCHMARKS.md / ROADMAP.md.
- **WebTransport** and **HTTP/3 server push** were evaluated and are blocked on
  upstream swift-nio-http3 (no H3 datagrams / WebTransport settings; no
  server-side push creation). Precise gap analysis in
  docs/upstream-issues/04.

## 0.4.0 — 2026-07-29

- **HTTP/3 streaming bodies**: incremental request and response bodies in both
  directions, preserving backpressure — for large uploads/downloads,
  server-sent events, and gRPC-style workloads.
  - Server: `server.run(streaming:)` with a `StreamingRequest` (head + body
    `AsyncSequence`) and a `ResponseWriter` (`writeHead`, `write`).
  - Client: `connection.withStreamingRequest(_:)` with a `RequestBodyWriter`
    (`write`, `finish`) and a `StreamingResponse` (lazy `head()` + body
    `AsyncSequence`).
  - Covered by full-duplex echo, streamed download, and streamed upload tests.
  The collected `HTTP3Request`/`HTTP3Response` API remains for the common case.

## 0.3.0 — 2026-07-29

- **HTTP/3 (RFC 9114)**: new `QUICHTTP3` product with `HTTP3Server` and
  `HTTP3Client`, async request/response over swift-nio-http3. GET/POST,
  headers, status codes, and multi-MiB bodies covered by end-to-end tests;
  verified against a production server (`cloudflare-quic.com`). Demo:
  `swift run quic-h3-demo`.
- Depends on a maintained fork of swift-nio-http3 (`adalinxx`, tag
  `0.1.0-swiftquic.1`) that exposes the `HTTP3`/`QPACK` products and pins the
  swift-nio-quic fork — an upstream PR to expose those products is planned.

An optional `localAddress` on `QUICClient.connect` (for NAT hole punching) is
proposed separately in PR #1.

## 0.2.0 — 2026-07-29

- **Versioned releases unblocked**: the maintained forks now carry prerelease
  tags, so the whole dependency chain is version-stable and swift-quic can be
  consumed with `from: "0.2.0"` instead of branch pinning.
- **Cross-implementation interop verified**: hash-verified 5 MiB transfers
  with quic-go (their server, our client) and quiche (their client, our
  server) over the hq-interop protocol.
- Added `QUICClient.Configuration.connectTimeout` (default 10 s) so connects
  to unresponsive addresses fail fast; covered by a black-hole test.
- Fourth upstream crash class fixed in the swift-network-evolution fork
  ("Cannot attach to empty protocol" when a stream attach races TLS-failure
  teardown; 16 trap sites now throw).
- Added docs/production-guide.md with a candid readiness statement.

## Unreleased (history)

- The package now pins maintained forks of `swift-nio-quic` and
  `swift-network-evolution` carrying fixes for three upstream bugs we found
  (typed reset errors, datagram write-promise completion on attach failure,
  and a process crash when operations race TLS-failure teardown). Upstream
  PRs are prepared; the forks retire once Apple merges equivalent fixes.
  See ROADMAP.md and docs/upstream-issues/.

## 0.1.0 — 2026-07-28

Initial release.

- Async/await QUIC client and server over `apple/swift-nio-quic`:
  `QUICServer`, `QUICClient`, `QUICConnection`, `QUICStream`.
- Bidirectional and unidirectional streams (both directions) with
  flow-control-aware backpressure; half-close, `RESET_STREAM`,
  `STOP_SENDING`; typed errors carrying peer application error codes.
- Unreliable datagrams (RFC 9221) with bounded drop-oldest receive buffering.
- TLS: PEM files, in-memory certificates, raw public keys (RFC 7250),
  self-signed development identities, hybrid post-quantum X25519MLKEM768.
- Graceful shutdown, keep-alive, Retry address validation, swift-metrics and
  qlog hooks.
- macOS 26+ and Linux support; 53 tests including seeded loss/reordering/
  duplication network simulation; nightly soak test; loopback benchmarks;
  QUIC Interop Runner endpoint scaffold.

> **Consumption note**: SwiftPM cannot resolve this package *by version*
> while it pins an untagged upstream revision (upstream's datagram support is
> not in a tag yet). Depend on it with `branch: "main"` — the `0.1.0` tag is a
> stable snapshot marker. See ROADMAP.md.
