# QUIC Interop Runner endpoint

This directory contains a [QUIC Interop Runner](https://github.com/quic-interop/quic-interop-runner)
endpoint for swift-quic, speaking the `hq-interop` application protocol.

**Status: cross-implementation transfer verified.** Hash-verified 5 MiB
`transfer` runs on a shared Docker network (2026-07-29):

| Direction | Peer | Result |
|---|---|---|
| swift-quic client ← server | quic-go (`martenseemann/quic-go-interop`) | ✅ SHA-256 match |
| client → swift-quic server | quiche (`cloudflare/quiche-qns`, `quiche-client --no-verify`) | ✅ SHA-256 match |

Full runner-matrix automation is still pending (the official runner needs its
ns-3 simulator; several implementations' *client* roles hang without it — 
quic-go's client does, which is why quiche covers the inbound direction).
See [ROADMAP.md](../ROADMAP.md).

## Supported test cases

- `handshake`
- `transfer`
- `retry` (server responds with Retry packets for address validation)
- `multiconnect`

Unsupported test cases exit with status 127, per the runner contract.
Notable gaps (tracked in the roadmap, mostly blocked on the upstream stack):
`resumption`, `zerortt`, `versionnegotiation`, `keyupdate`, `chacha20`,
`ecn`, `http3`.

## Building the image

```
docker build -f interop/Dockerfile -t swift-quic-interop .
```

## Local smoke test without the runner

```
# Terminal 1 (server)
mkdir -p /tmp/interop/{certs,www,downloads}
# put cert.pem/priv.key in certs/, a test file in www/
ROLE=server TESTCASE=transfer CERTS_DIR=/tmp/interop/certs \
  WWW_DIR=/tmp/interop/www PORT=4433 \
  swift run quic-interop

# Terminal 2 (client)
ROLE=client TESTCASE=transfer DOWNLOADS_DIR=/tmp/interop/downloads \
  REQUESTS="https://127.0.0.1:4433/testfile" \
  swift run quic-interop
```
