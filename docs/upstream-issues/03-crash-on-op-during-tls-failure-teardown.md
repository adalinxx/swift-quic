# Draft upstream issue: crash when an operation races TLS-failure teardown

**Target repo**: apple/swift-network-evolution (surfaced via apple/swift-nio-quic)
**Found at**: swift-network-evolution 0.1.1 / swift-nio-quic revision 19fd6ac

## Summary

When a connection is torn down because the TLS handshake failed (untrusted
certificate or ALPN mismatch), an operation still in flight from the upper
protocol (stream write/open forwarded through NIOQUIC) can reach a
`ProtocolInstance` whose event-state index has already been detached,
crashing the process:

```
SwiftNetwork/ProtocolEventManager.swift:644: Fatal error: Unexpectedly found nil while unwrapping an Optional value
```

Line 644 is the force unwrap in:

```swift
func handleCallFromUpperProtocol<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    let protocolEventStateIndex = protocolEventStateIndex()!   // <- crashes
    ...
```

Immediately preceded in the log by:

```
[SwiftNetwork] handleDisconnectedEvent(error:) Disconnected: TLS error Unknown error -9858
```

## Reproduction

Client connects to a server whose certificate it does not trust (or with a
non-overlapping ALPN list), then immediately attempts to open a stream and
write to it while the handshake failure propagates. Timing-dependent:

- Reproduces readily on Linux x86_64 (2-core GitHub runner, `swift:6.3`
  image, `swift test --parallel`).
- Also reproduces on macOS when the dependency tree is built with the
  Swift 6.4 toolchain.
- Rare on macOS arm64 / Linux arm64 with Swift 6.3.

## Expected

Calls from the upper protocol after detach should fail gracefully (throw /
error the write promise), not crash the process.

## Workaround

Downstream can pre-check `Channel.isActive` before forwarding operations,
which narrows but cannot close the race window.
