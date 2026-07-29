# Contributing to swift-quic

Thanks for your interest! Contributions of all kinds are welcome: bug
reports, tests, docs, benchmarks, and code.

## Getting started

```
git clone https://github.com/adalinxx/swift-quic
cd swift-quic
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift test
```

Requirements: Swift 6.3, macOS 26+ or Linux (a `swift:6.3` container works —
see the CI workflow for the exact invocation).

## Ground rules

- **Tests**: every behavior change comes with a test. Integration tests run
  over real loopback UDP; see `Tests/QUICIntegrationTests/TestHarness.swift`
  for the harness, and `LossyNetworkTests.swift` if your change affects loss
  recovery paths.
- **Concurrency**: the package builds with `StrictConcurrency`; keep it
  warning-free. Public awaits must be cancellation-safe — never expose a bare
  `EventLoopFuture.get()` on a path that can stall (see
  `Internal/CancellableFutureAwait.swift`).
- **API**: follow the Swift API Design Guidelines. Public API needs DocC
  comments. Prefer additive changes; we track API breakage in review.
- **Performance**: for changes on the data path, run
  `swift run -c release quic-bench` before and after and include the numbers
  in the PR description.
- **Upstream layering**: this library wraps `apple/swift-nio-quic`. Protocol
  behavior belongs upstream; this repo owns the API surface, bridging, and
  ergonomics. If you hit a protocol bug, check
  [docs/upstream-issues/](docs/upstream-issues/) and the upstream issue
  tracker first.

## Pull requests

1. Fork, branch from `main`.
2. `SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift test` must pass.
3. Open a PR with a clear description of the problem and the approach.

CI runs macOS and Linux test suites on every PR, plus a nightly soak test.

## Reporting security issues

Please do not open public issues for security problems — see
[SECURITY.md](SECURITY.md).
