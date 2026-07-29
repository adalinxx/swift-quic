# ``QUIC``

An easy-to-use Swift QUIC library: async/await streams and datagrams over
Apple's SwiftNIO QUIC stack.

## Overview

`QUIC` wraps [swift-nio-quic](https://github.com/apple/swift-nio-quic) in a
small, modern API. Servers accept connections as an `AsyncSequence`; each
connection multiplexes reliable ``QUICStream``s and unreliable datagrams
(RFC 9221).

```swift
// Client
var configuration = QUICClient.Configuration(applicationProtocols: ["my-proto"])
try await QUICClient.withConnection(to: "example.com", port: 4433, configuration: configuration) { connection in
    let stream = try await connection.openBidirectionalStream()
    try await stream.send("hello")
    try await stream.finish()
    print(String(buffer: try await stream.collect(upTo: 1 << 20)))
}
```

## Topics

### Connecting and serving

- ``QUICClient``
- ``QUICServer``
- ``QUICConnection``

### Streams

- ``QUICStream``
- ``QUICStreamID``
- ``QUICStreamInitiator``

### Configuration

- ``QUICTransportConfiguration``
- ``QUICIdentity``
- ``QUICSelfSignedIdentity``
- ``QUICTrustRoots``
- ``QUICCertificateVerification``
- ``QUICKeyExchangeGroup``
- ``QUICQLogConfiguration``
- ``QUICMetrics``

### Errors

- ``QUICStreamError``
- ``QUICConnectionError``
- ``QUICConfigurationError``
- ``QUICApplicationErrorCode``
- ``QUICStreamCollectError``
