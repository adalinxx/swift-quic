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

/// The wire coding for HTTP/3 datagrams (RFC 9297 § 2.1) and the capsule
/// protocol (RFC 9297 § 3.2).
///
/// These are the framing primitives WebTransport (and MASQUE) build on. They
/// are pure value transforms — the transport wiring that carries them over
/// QUIC datagrams / the CONNECT stream is layered on top.
public enum HTTP3DatagramCodec {
    /// HTTP/3 datagram setting identifier `SETTINGS_H3_DATAGRAM` (RFC 9297).
    public static let h3DatagramSettingID: UInt64 = 0x33
    /// `SETTINGS_ENABLE_CONNECT_PROTOCOL` (RFC 9220 / extended CONNECT).
    public static let enableConnectProtocolSettingID: UInt64 = 0x08
    /// `SETTINGS_WT_MAX_SESSIONS` (WebTransport over HTTP/3 draft).
    public static let webTransportMaxSessionsSettingID: UInt64 = 0xC671_706A

    /// Encodes an HTTP/3 datagram payload for the request stream `streamID`.
    ///
    /// Wire form (RFC 9297 § 2.1): `Quarter Stream ID (varint) || payload`,
    /// where the Quarter Stream ID is `streamID / 4`.
    public static func encodeDatagram(streamID: UInt64, payload: ByteBuffer) -> ByteBuffer {
        let quarter = streamID / 4
        var out = ByteBuffer()
        out.reserveCapacity(QUICVarint.encodedLength(quarter) + payload.readableBytes)
        QUICVarint.write(quarter, to: &out)
        var payload = payload
        out.writeBuffer(&payload)
        return out
    }

    /// Decodes an HTTP/3 datagram into its owning request stream ID and payload.
    ///
    /// - Returns: `nil` if the quarter-stream-id varint is malformed.
    public static func decodeDatagram(_ datagram: ByteBuffer) -> (streamID: UInt64, payload: ByteBuffer)? {
        var datagram = datagram
        guard let quarter = QUICVarint.read(from: &datagram) else { return nil }
        guard quarter <= QUICVarint.max / 4 else { return nil }
        return (streamID: quarter * 4, payload: datagram.slice())
    }

    /// A capsule (RFC 9297 § 3.2): a typed, length-prefixed message carried in
    /// the body of an extended-CONNECT stream.
    public struct Capsule: Hashable, Sendable {
        /// The capsule type (a varint).
        public var type: UInt64
        /// The capsule value.
        public var value: ByteBuffer

        public init(type: UInt64, value: ByteBuffer) {
            self.type = type
            self.value = value
        }
    }

    /// Appends a capsule to `buffer`: `Type (varint) || Length (varint) || Value`.
    public static func writeCapsule(_ capsule: Capsule, to buffer: inout ByteBuffer) {
        QUICVarint.write(capsule.type, to: &buffer)
        QUICVarint.write(UInt64(capsule.value.readableBytes), to: &buffer)
        var value = capsule.value
        buffer.writeBuffer(&value)
    }

    /// Reads one capsule from `buffer`, advancing the reader index only if a
    /// complete capsule is present.
    ///
    /// - Returns: The capsule, or `nil` if `buffer` does not yet hold a full
    ///   capsule (the reader index is left unchanged in that case).
    public static func readCapsule(from buffer: inout ByteBuffer) -> Capsule? {
        let savedIndex = buffer.readerIndex
        guard let type = QUICVarint.read(from: &buffer),
            let length = QUICVarint.read(from: &buffer),
            let value = buffer.readSlice(length: Int(length))
        else {
            buffer.moveReaderIndex(to: savedIndex)
            return nil
        }
        return Capsule(type: type, value: value)
    }
}
