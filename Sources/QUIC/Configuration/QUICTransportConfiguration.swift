//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Tunable QUIC transport parameters shared by clients and servers.
///
/// The defaults are sensible for most applications; you rarely need to change
/// them.
public struct QUICTransportConfiguration: Hashable, Sendable {
    /// How long the connection may stay idle before it is closed.
    /// Defaults to 30 seconds.
    public var maxIdleTimeout: Duration = .seconds(30)

    /// The connection-level flow control window, in bytes.
    /// Defaults to 16 MiB.
    public var initialMaxData: Int = 16 * 1024 * 1024

    /// The per-stream flow control window for locally-initiated bidirectional
    /// streams, in bytes. Defaults to 2 MiB.
    public var initialMaxStreamDataBidirectionalLocal: Int = 2 * 1024 * 1024

    /// The per-stream flow control window for remotely-initiated bidirectional
    /// streams, in bytes. Defaults to 2 MiB.
    public var initialMaxStreamDataBidirectionalRemote: Int = 2 * 1024 * 1024

    /// The per-stream flow control window for unidirectional streams, in bytes.
    /// Defaults to 2 MiB.
    public var initialMaxStreamDataUnidirectional: Int = 2 * 1024 * 1024

    /// The number of concurrent bidirectional streams the *peer* may open.
    /// Defaults to 100.
    public var maxBidirectionalStreams: Int = 100

    /// The number of concurrent unidirectional streams the *peer* may open.
    /// Defaults to 100.
    public var maxUnidirectionalStreams: Int = 100

    /// When set, PING frames are sent at this interval to keep the connection
    /// (and any NAT bindings) alive. Defaults to `nil` (no keep-alive).
    public var keepAliveInterval: Duration? = nil

    /// Support for unreliable QUIC datagrams (RFC 9221).
    public var datagrams: Datagrams = Datagrams()

    /// Configuration for unreliable QUIC datagrams (RFC 9221).
    public struct Datagrams: Hashable, Sendable {
        /// Whether to advertise datagram support to the peer. Defaults to `true`.
        public var isEnabled: Bool = true

        /// The largest datagram frame we are willing to receive, in bytes.
        /// Defaults to 65535.
        public var maxFrameSize: Int = 65535

        /// How many received datagrams to buffer while the application is not
        /// reading them. Once full, the oldest buffered datagrams are dropped
        /// (datagrams are unreliable by design). Defaults to 64.
        public var receiveBufferCount: Int = 64

        /// Creates a datagram configuration with the default values.
        public init() {}
    }

    /// Creates a transport configuration with the default values.
    public init() {}
}
