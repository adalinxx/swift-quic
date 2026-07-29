//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// The endpoint that initiated a stream.
public enum QUICStreamInitiator: Hashable, Sendable {
    case client
    case server
}

/// A QUIC stream identifier (RFC 9000 § 2.1).
///
/// Stream IDs are 62-bit integers that are unique within a connection. The two
/// least significant bits encode the initiator and directionality of the
/// stream, exposed here as ``initiator`` and ``isBidirectional``.
public struct QUICStreamID: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The raw 62-bit stream ID value.
    public let rawValue: UInt64

    /// Creates a stream ID from its raw value.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Which endpoint opened this stream.
    public var initiator: QUICStreamInitiator {
        (self.rawValue & 0x1) == 0 ? .client : .server
    }

    /// Whether this stream carries data in both directions.
    public var isBidirectional: Bool {
        (self.rawValue & 0x2) == 0
    }

    /// Whether this stream carries data in one direction only.
    public var isUnidirectional: Bool {
        !self.isBidirectional
    }

    public static func < (lhs: QUICStreamID, rhs: QUICStreamID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        let direction = self.isBidirectional ? "bidirectional" : "unidirectional"
        return "\(self.rawValue) (\(self.initiator)-initiated, \(direction))"
    }
}

/// Which end of the connection we are. Internal: used to derive stream
/// writability.
enum EndpointRole: Sendable {
    case client
    case server

    var streamInitiator: QUICStreamInitiator {
        switch self {
        case .client: return .client
        case .server: return .server
        }
    }
}
