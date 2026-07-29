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
(`datagramVectorReadMessageCount = 8`), so the kernel can hand up to 8
datagrams per `recvmmsg` syscall. This reduces per-packet syscall overhead on
**busy servers handling many connections/packets**; a single-connection
loopback microbench is syscall-light and shows it as neutral (measured within
run-to-run noise), which is expected — the win is in packet-rate-bound
multi-flow scenarios the loopback bench does not model.

## Known optimization opportunities

Tracked in [ROADMAP.md](ROADMAP.md): send-side batching (`sendmmsg`), buffer
reuse in the stream bridge, and an allocation-counter regression harness
(swift-nio's `run-allocation-counter.sh` framework, still to be wired in).
