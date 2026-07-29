# Draft upstream issue: peer RESET_STREAM can surface as a raw `NetworkError`

**Target repo**: apple/swift-nio-quic
**Found at revision**: 19fd6ac5de463717fb1d957381a91ff96f5623b5

## Summary

When a peer sends `RESET_STREAM`, the stream channel usually surfaces
`NIOQUICHelpers.QUICStreamResetError` (via
`QUICChannelStreamHandler.surfaceReadCompletion` → `.reportPeerReset`). But in
a teardown race, the reset instead arrives via
`handleDisconnectedEvent(error:)` → `_close(error:)`, which fires the raw
`SwiftNetwork.NetworkError` into the pipeline. Two variants observed:

1. `NetworkError` carrying `quicApplicationError` (code preserved but the
   typed error is lost — callers must SPI-import SwiftNetwork to read it).
2. A bare POSIX `ECONNRESET` `NetworkError` ("Connection reset by peer") with
   the application error code lost entirely.

The trace shows the race: the reset arrives while the stream pipeline is
still initializing ("surfaceReset: pipeline not yet initialized, will surface
on next read"), and the disconnect event then closes the channel with the raw
error before the deferred surface happens:

```
[Client][S0] Received reset stream error applicationErrorCode=77
[Client][S0] surfaceReset: pipeline not yet initialized, will surface on next read
[Client][S0] handleDisconnectedEvent error: Optional(Connection reset by peer)
[Client][S0] _close error: Optional(Connection reset by peer)
```

## Reproduction

Server: accept a bidirectional stream, read one chunk, immediately send
`QUICResetStreamEvent(code: 77)`. Client: open the stream, write, read.
Race window is small but hits reliably within a few dozen runs on loopback
(the reset must arrive while the client stream channel initializer is still
in flight).

## Expected

The stream pipeline always observes `QUICStreamResetError(code:)` for a peer
reset, regardless of arrival timing.

## Workaround

Downstream consumers can map `NetworkError` (checking `quicApplicationError`,
and POSIX `ECONNRESET` as a fallback) to their own typed reset error — this is
what swift-quic does in `StreamBridge.errorCaught`/`QUICStream.mapWriteError`.
