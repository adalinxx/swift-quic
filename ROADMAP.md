# Roadmap

An honest map of where swift-quic is versus a state-of-the-art QUIC library,
split by who can move each item.

## Done

- Async/await API: connections, streams, and datagrams as `AsyncSequence`s,
  scoped lifetimes, typed errors carrying peer application error codes.
- RFC 9221 unreliable datagrams with bounded drop-oldest receive buffering.
- Half-close, `RESET_STREAM`, `STOP_SENDING`, application-error
  `CONNECTION_CLOSE`, graceful server shutdown.
- TLS: PEM files, in-memory certificates, raw public keys (RFC 7250),
  one-line self-signed development identities, hybrid post-quantum
  X25519MLKEM768 key exchange.
- Linux support (Ubuntu via `swift:6.3` containers) with CI.
- Adverse-network tests: seeded loss/reordering/duplication UDP proxy;
  nightly soak test; 53-test suite on macOS and Linux.
- Loopback benchmark suite with published reference numbers
  ([BENCHMARKS.md](BENCHMARKS.md)).
- QUIC Interop Runner endpoint (`hq-interop`) with **verified
  cross-implementation transfers against quic-go and quiche**
  ([interop/](interop/)).
- Client connect timeout (default 10 s) with black-hole test coverage.
- **Versioned releases**: fork prerelease tags make the dependency chain
  version-stable; consume via `from: "0.2.0"`.

## In progress (ours to do)

- **Interop matrix validation**: bidirectional hash-verified transfers
  against quic-go (as server) and quiche (as client) already pass — see
  [interop/](interop/). Remaining: the full official runner matrix (needs its
  ns-3 simulator), more implementations, and verifying RSA server identities
  (the runner's default certs) against the SwiftTLS signing path.
- **Performance**: UDP batching (`sendmmsg`/`recvmmsg`) exploration, buffer
  reuse in the stream bridge, allocation-counter regression tests.
- **HTTP/3 convenience layer** on top of streams (upstream has
  swift-nio-http3 integration to build on).
- **Connection statistics API** (RTT, congestion window, loss counters) —
  partially exposed today via swift-metrics at connection close; a live
  per-connection query needs upstream surface.

## Blocked on the upstream stack (apple/swift-nio-quic & swift-network-evolution)

| Item | Blocker |
|---|---|
| Semver releases consumable via `from: "x.y.z"` | SwiftPM forbids stable-version packages from depending on unversioned packages, and the datagram-capable upstream code is only on `main` (latest tag 0.1.0 predates it). The moment upstream tags, we re-pin and release properly. |
| 0-RTT / session resumption | Not yet exposed by upstream (only early-data rejection plumbing exists). |
| Connection migration / preferred address / multipath | No upstream surface. |
| Congestion control selection (BBR), pacing, ECN | Upstream is CUBIC-only, not configurable. |
| mTLS (client certificates) | apple/swift-nio-quic#5. |
| `SSLKEYLOGFILE` output | apple/swift-nio-quic#7 (`setKeylogPath` is a TODO); our config knob is plumbed and documented as a no-op. |
| Stream priorities (RFC 9218 scheduling) | Requires upstream write-scheduler control. |
| Thread Sanitizer CI | The Swift 6.3 compiler crashes (signal 6) compiling the dependency tree with `-sanitize=thread`; retry on newer toolchains. |

## Upstream bugs: found, fixed in our forks, PRs prepared

We found three bugs in the upstream stack, **fixed them in maintained forks
that this package now pins** (`adalinxx/swift-nio-quic`,
`adalinxx/swift-network-evolution`), and prepared upstream pull requests —
see [docs/upstream-issues/](docs/upstream-issues/):

1. Peer `RESET_STREAM` surfacing as a raw `NetworkError` instead of
   `QUICStreamResetError` (fixed on the disconnect path; the bare-POSIX
   variant is noted as follow-up since the code is lost at a lower layer).
2. Early datagram writes buffered forever when the datagram flow fails to
   attach (now failed immediately, with a regression test).
3. Process crash (`ProtocolEventManager` force-unwrap) when operations race
   TLS-failure teardown (all eight trap sites now guard on detachment).

The forks track upstream `main`; when Apple merges the PRs (or ships
equivalent fixes), we re-pin to upstream and the forks retire. The library's
own defensive layers (error mapping, cancellation-safe awaits, close-flag
guards) stay regardless.
