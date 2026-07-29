//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// QUIC variable-length integer coding (RFC 9000 § 16).
///
/// The two most-significant bits of the first byte select a 1, 2, 4, or 8-byte
/// encoding; the remaining 62 bits are the value. Used by HTTP/3 datagrams and
/// the capsule protocol (RFC 9297).
public enum QUICVarint {
    /// The largest value a QUIC varint can hold (2^62 - 1).
    public static let max: UInt64 = (1 << 62) - 1

    /// The number of bytes `value` encodes to.
    public static func encodedLength(_ value: UInt64) -> Int {
        switch value {
        case 0..<(1 << 6): return 1
        case 0..<(1 << 14): return 2
        case 0..<(1 << 30): return 4
        default: return 8
        }
    }

    /// Appends `value` to `buffer` in QUIC varint form.
    ///
    /// - Precondition: `value` must be ≤ ``max``.
    public static func write(_ value: UInt64, to buffer: inout ByteBuffer) {
        precondition(value <= Self.max, "value \(value) exceeds QUIC varint range")
        switch Self.encodedLength(value) {
        case 1:
            buffer.writeInteger(UInt8(value))
        case 2:
            buffer.writeInteger(UInt16(value) | (0b01 << 14))
        case 4:
            buffer.writeInteger(UInt32(value) | (0b10 << 30))
        default:
            buffer.writeInteger(value | (0b11 << 62))
        }
    }

    /// Reads a QUIC varint from `buffer`, advancing the reader index.
    ///
    /// - Returns: The decoded value, or `nil` if the buffer does not hold a
    ///   complete varint.
    public static func read(from buffer: inout ByteBuffer) -> UInt64? {
        guard let first = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
            return nil
        }
        let prefix = first >> 6
        let length = 1 << Int(prefix)  // 1, 2, 4, or 8
        guard buffer.readableBytes >= length else { return nil }

        switch length {
        case 1:
            return UInt64(buffer.readInteger(as: UInt8.self)! & 0x3F)
        case 2:
            return UInt64(buffer.readInteger(as: UInt16.self)! & 0x3FFF)
        case 4:
            return UInt64(buffer.readInteger(as: UInt32.self)! & 0x3FFF_FFFF)
        default:
            return buffer.readInteger(as: UInt64.self)! & 0x3FFF_FFFF_FFFF_FFFF
        }
    }
}
