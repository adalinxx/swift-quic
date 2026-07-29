# Changelog

## Unreleased

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
