//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOQUICHelpers

/// An application-defined error code carried in QUIC `RESET_STREAM`,
/// `STOP_SENDING`, and `CONNECTION_CLOSE` frames.
///
/// Application error codes are opaque to the QUIC transport: their meaning is
/// defined entirely by the application protocol running on top of QUIC
/// (RFC 9000 § 20.2). The value must fit in a QUIC variable-length integer,
/// i.e. it must be less than 2^62.
public struct QUICApplicationErrorCode: Hashable, Sendable, RawRepresentable, ExpressibleByIntegerLiteral,
    CustomStringConvertible
{
    /// The maximum representable error code value (2^62 - 1).
    public static let maxValue: UInt64 = (1 << 62) - 1

    /// The raw error code value.
    public let rawValue: UInt64

    /// The "no error" code (`0`). Use this when closing without signalling a failure.
    public static let noError: QUICApplicationErrorCode = 0

    /// Creates an error code, returning `nil` if `rawValue` exceeds ``maxValue``.
    public init?(rawValue: UInt64) {
        guard rawValue <= Self.maxValue else { return nil }
        self.rawValue = rawValue
    }

    /// Creates an error code from an integer literal.
    ///
    /// - Precondition: `value` must be less than 2^62.
    public init(integerLiteral value: UInt64) {
        precondition(value <= Self.maxValue, "QUIC application error codes must be < 2^62")
        self.rawValue = value
    }

    public var description: String {
        String(self.rawValue)
    }
}

extension QUICApplicationErrorCode {
    /// Converts to the NIOQUICHelpers representation.
    var helperCode: NIOQUICHelpers.QUICApplicationErrorCode {
        // Safe: both types enforce the same 2^62 bound.
        NIOQUICHelpers.QUICApplicationErrorCode(self.rawValue)!
    }

    init(_ helperCode: NIOQUICHelpers.QUICApplicationErrorCode) {
        self.rawValue = helperCode.rawValue
    }
}
