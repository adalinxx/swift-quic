# Production guide

What to know before running swift-quic in production.

## Readiness statement

swift-quic's API layer is thoroughly tested: 56 unit/integration tests on
macOS and Linux, adverse-network simulation (loss/reordering/duplication),
nightly soak runs, cross-implementation interop checks, and loopback
benchmarks. The underlying protocol stack is Apple's swift-nio-quic /
swift-network-evolution — **pre-1.0 software** — pinned via maintained forks
that fix four crash/hang classes we found (upstream PRs prepared). Treat the
whole as production-capable for internal services and controlled rollouts,
not yet for hostile-internet edge exposure: the upstream stack has not had a
public security audit, and protocol-level fuzzing is still on the roadmap.

## Configuration checklist

- **TLS**: use real certificates (`.certificateChain(pemFile:privateKeyPEMFile:)`
  or in-memory `.certificates`). `QUICIdentity.selfSigned` and
  `certificateVerification = .none` are for development only.
- **ALPN**: set `applicationProtocols` to your protocol identifier on both
  sides; mismatch fails the handshake (by design).
- **Connect timeout**: `QUICClient.Configuration.connectTimeout` defaults to
  10 s. Lower it for latency-sensitive callers with fallbacks.
- **Idle timeout / keep-alive**: `transport.maxIdleTimeout` defaults to 30 s.
  For long-lived quiet connections set `transport.keepAliveInterval` below
  the idle timeout (e.g. 15 s) or the connection will close.
- **Flow control**: defaults (16 MiB connection / 2 MiB per stream) suit
  request-response. For high-bandwidth-delay paths, raise
  `initialMaxData` and the per-stream windows; for many-small-streams
  workloads raise `maxBidirectionalStreams`.
- **Datagrams**: unreliable by design; size sends against the peer's
  advertised limit (oversize throws `.datagramTooLarge`) and expect drops
  under load (`receiveBufferCount` bounds buffering, oldest dropped first).
- **Address validation**: enable `sendRetry` on internet-facing servers to
  resist spoofed-source floods (costs one round trip per new connection).

## Operational practices

- **Structured concurrency**: prefer `QUICClient.withConnection` and
  `server.run`; both guarantee teardown. Every await in the API honors task
  cancellation.
- **Error handling**: stream operations throw `QUICStreamError` (`.reset` /
  `.stopSendingReceived` carry the peer's application error code); connection
  operations throw `QUICConnectionError`. Both are stable API.
- **Metrics**: install `QUICMetrics` (swift-metrics) in the configuration to
  record connection counts, packet/RTT/congestion statistics at close, and
  stream lifetimes.
- **Logging**: transport logs go to the configuration's `logger`. `.info` is
  quiet; `.trace` is per-packet (development only).
- **Graceful deploys**: call `server.shutdownGracefully(timeout:)` — stops
  accepting, drains connections until the deadline, then closes.

## Known limits (see ROADMAP.md)

No 0-RTT/session resumption, no connection migration, CUBIC-only congestion
control, no mTLS, keylog is a no-op — all pending the upstream stack. One
UDP socket per client connection. Server accept and stream queues are
unbounded `AsyncStream`s; extreme accept floods should be rate-limited in
front (the Retry mechanism helps).
