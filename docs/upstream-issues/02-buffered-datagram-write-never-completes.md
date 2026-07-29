# Draft upstream issue: early datagram write can be buffered forever

**Target repo**: apple/swift-nio-quic
**Found at revision**: 19fd6ac5de463717fb1d957381a91ff96f5623b5

## Summary

`QUICDatagramHandler` buffers datagram writes made before the peer's
`max_datagram_frame_size` is known (`.waitingForPeerAdvertisement`), resolving
them when `setBackend(to:withPeerMaxDatagramFrameSize:)` runs. That call
happens in `QUICChannelNewFlowHandler` when the datagram flow attaches — and
if `invokeAttachUpperDatagramProtocolToNewFlow` throws, the error is only
logged:

```swift
} catch {
    self.logger.error("... Failed to attach QUIC datagram flow: \(error)")
}
```

After that, the handler stays in `.waitingForPeerAdvertisement` forever:

- Buffered write promises never complete (a caller awaiting
  `writeAndFlush(...).get()` is stuck permanently — `get()` is not
  cancellable).
- The buffered promises are also not failed on channel teardown
  (`handlerRemoved`/close paths don't drain `earlyWrites`), which risks
  promise-leak assertions in debug builds.

Observed as an intermittent, permanent hang in a test that sent a datagram
immediately after `createOutboundConnection` completed (roughly 1-in-5 runs
under parallel test load on loopback; the process sat fully idle).

## Expected

Either fail buffered writes when the datagram flow fails to attach (and on
channel teardown), or propagate the attach failure into the pipeline.

## Workaround

Downstream: await datagram write promises with a cancellation-safe wrapper so
callers can escape (swift-quic's `withCancellableWait`), and/or delay the
first datagram until after an application-level round trip.
