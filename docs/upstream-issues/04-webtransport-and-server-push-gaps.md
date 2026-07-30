# Upstream gaps: WebTransport and HTTP/3 server push

Both are widely-cited "SOTA" QUIC/HTTP-3 features. Neither is buildable on the
current stack without implementing substantial new protocol machinery upstream
(in `apple/swift-nio-http3`), so they are **not shipped** in swift-quic — this
records exactly why, so the gap is honest and actionable rather than hidden.

## WebTransport (over HTTP/3)

WebTransport (`draft-ietf-webtrans-http3`) needs several HTTP/3 features that
do not exist in swift-nio-http3 today:

1. **HTTP/3 datagrams (RFC 9297).** WebTransport datagrams ride on H3 datagrams
   with a quarter-stream-id context bound to the CONNECT stream. A search of
   `Sources/HTTP3` and `Sources/NIOHTTP3` finds **no datagram framing at all**.
   (swift-quic has RFC 9221 *transport* datagrams, but WebTransport requires the
   RFC 9297 *HTTP-layer* mapping, which is a different, absent feature.)
2. **`SETTINGS_ENABLE_WEBTRANSPORT` / `SETTINGS_ENABLE_CONNECT_PROTOCOL` /
   `SETTINGS_H3_DATAGRAM`.** `HTTP3Setting.swift` defines none of these; the
   settings negotiation needed to turn WebTransport on is not present.
3. **Stream ↔ session association.** WebTransport streams are QUIC streams
   whose first bytes signal the owning session; there is no upstream surface to
   create or route these.

Extended CONNECT itself is partially present — the codec can encode the
`:protocol` pseudo-header (`HTTP3ToHTTPCodecs.swift`) — but that is a small
fraction of what WebTransport requires.

**Status update.** Re-evaluated: two of the three sub-blocks are *not* as
blocked as first thought.

- **Settings** are extensible after all: `HTTP3Setting.Identifier(extensionSetting:)`
  accepts arbitrary identifiers and `HTTP3Settings` round-trips unknown ones, so
  `SETTINGS_H3_DATAGRAM`, `ENABLE_CONNECT_PROTOCOL`, and the WebTransport
  settings can be negotiated without forking.
- **Wire framing** is now implemented in swift-quic: `HTTP3DatagramCodec` and
  `QUICVarint` (RFC 9000 § 16 / RFC 9297 § 2.1 § 3.2) encode/decode HTTP/3
  datagrams (quarter-stream-id + payload) and capsules, with 9 unit tests
  including the RFC 9000 § A.1 known-answer vector.

**Status: shipped.** WebTransport is implemented in swift-quic
(`WebTransportServer`/`WebTransportClient`, `WebTransportSession`,
`WebTransportStream`) and end-to-end tested on macOS and Linux:

1. **Datagram routing — done.** A `WebTransportConnectionHandler` on the
   connection-channel pipeline (ahead of `HTTP3ConnectionHandler`) demultiplexes
   inbound QUIC datagrams to the owning session by quarter-stream-id and
   originates outbound datagram writes.
2. **Session lifecycle — done.** Extended CONNECT (`:protocol=webtransport`) is
   accepted server-side and issued client-side; the CONNECT stream is held open
   for the session's lifetime and torn down on app/peer/connection close.
3. **Streams — done.** `WebTransportSession.openBidirectionalStream()` /
   `openUnidirectionalStream()` and `incomingStreams` create and accept
   type-prefixed (`0x41`/`0x54` + session ID) QUIC streams. A per-stream inbound
   router peeks the first varint(s) to divert WebTransport streams to their
   session while replaying non-WebTransport bytes to HTTP/3 unchanged.

The one fork change required was extended-CONNECT validation (RFC 9220) in
swift-nio-http3, prepared as an upstream PR. Remaining nice-to-have: interop
against a browser or `webtransport-go`.

## HTTP/3 server push

swift-nio-http3's async interface exposes a client-side
`inboundPushStreamInitializer` (to *receive* a push), but:

- Creating pushes on the **server** side is an explicit upstream TODO
  (`HTTP3ConnectionMultiplexer.swift`: "Allow creating outbound push streams").
- Iterating incoming push streams is also a TODO (upstream issue #1).

So server push cannot be exercised end to end within this stack (we cannot
originate a push to test reception), and shipping a receive-only hook we can't
test would be dishonest. Server push is also effectively deprecated across the
ecosystem (removed from Chrome), which lowers its priority.

**Conclusion:** blocked on server-side push creation in swift-nio-http3;
low priority given ecosystem deprecation. The client receive hook will be
surfaced if/when upstream completes the outbound-push API so it can be tested.
