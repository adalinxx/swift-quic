# Benchmarks

Loopback benchmarks live in `Sources/quic-bench`. Client and server run in a
single process over 127.0.0.1, so the numbers measure the QUIC stack and this
library's overhead — not a real network path.

Run them with:

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift run -c release quic-bench
```

## Reference numbers

Apple Silicon (arm64), macOS 26.3, Swift 6.3.3, release build, 2026-07-28:

| Benchmark | Result |
|---|---|
| Connect + first stream round trip, p50 | 1.28 ms |
| Connect + first stream round trip, p99 | 8.60 ms |
| Bulk echo throughput (64 MiB payload) | 1.06 Gbit/s of stack crossings |
| Sequential request/response streams | ~6,900 streams/s |
| Concurrent request/response streams (width 32) | ~16,600 streams/s |
| Datagram ping-pong (1000 B) | ~12,700 round trips/s, 0 dropped |

Notes:

- "Stack crossings" counts each byte twice for the echo (client→server and
  server→client), i.e. one-way goodput is half the listed figure.
- Numbers vary run to run (single process, shared event loop group); treat
  them as order-of-magnitude reference points and always compare like against
  like on the same machine.
- CI does not run benchmarks: shared runners are far too noisy for regression
  detection. Run locally before and after performance-relevant changes.
- Bulk loopback throughput is **highly sensitive to machine load** — a busy
  workstation (background compiles, containers) can drop the single-connection
  echo figure several-fold. Measure on an otherwise-idle machine and only
  compare runs taken back-to-back.

## Datagram batching (recvmmsg)

All UDP sockets enable NIO's vectored datagram reads
(`datagramVectorReadMessageCount = 8`) so the kernel can return up to 8
datagrams per `recvmmsg` syscall on Linux, cutting per-packet syscall overhead
on busy servers.

The critical detail: NIO's vectored read splits **one** receive buffer into N
equal slots, so the receive allocator must give each slot room for a full
datagram. We pair the option with
`FixedSizeRecvByteBufferAllocator(capacity: 8 * 2048)` (2 KiB per slot). An
earlier attempt without this truncated every packet and broke all Linux
handshakes — caught by the Linux CI job. (On Darwin there is no `recvmmsg`, so
the option is a no-op; the win is Linux-only, which is where servers run.)

## Known optimization opportunities

Tracked in [ROADMAP.md](ROADMAP.md): send-side batching (`sendmmsg`), buffer
reuse in the stream bridge, and an allocation-counter regression harness
(swift-nio's `run-allocation-counter.sh` framework, still to be wired in).
