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
import Testing

@testable import QUICHTTP3

@Suite
struct QUICVarintTests {
    @Test
    func encodedLengthBoundaries() {
        #expect(QUICVarint.encodedLength(0) == 1)
        #expect(QUICVarint.encodedLength(63) == 1)
        #expect(QUICVarint.encodedLength(64) == 2)
        #expect(QUICVarint.encodedLength(16383) == 2)
        #expect(QUICVarint.encodedLength(16384) == 4)
        #expect(QUICVarint.encodedLength(1_073_741_823) == 4)
        #expect(QUICVarint.encodedLength(1_073_741_824) == 8)
        #expect(QUICVarint.encodedLength(QUICVarint.max) == 8)
    }

    @Test
    func roundTripsAcrossAllLengths() {
        let values: [UInt64] = [
            0, 1, 62, 63, 64, 100, 16383, 16384, 100_000,
            1_073_741_823, 1_073_741_824, 4_611_686_018_427_387_903, QUICVarint.max,
        ]
        for value in values {
            var buffer = ByteBuffer()
            QUICVarint.write(value, to: &buffer)
            #expect(buffer.readableBytes == QUICVarint.encodedLength(value))
            let decoded = QUICVarint.read(from: &buffer)
            #expect(decoded == value)
            #expect(buffer.readableBytes == 0)
        }
    }

    @Test
    func readReturnsNilOnTruncation() {
        // A 4-byte varint with only 2 bytes present.
        var full = ByteBuffer()
        QUICVarint.write(16384, to: &full)
        var truncated = full.getSlice(at: full.readerIndex, length: 2)!
        #expect(QUICVarint.read(from: &truncated) == nil)
    }

    @Test
    func matchesKnownRFC9000Encodings() {
        // RFC 9000 § A.1 sample: 151288809941952652 encodes to 8 bytes
        // 0xc2197c5eff14e88c.
        var buffer = ByteBuffer()
        QUICVarint.write(151_288_809_941_952_652, to: &buffer)
        #expect(Array(buffer.readableBytesView) == [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
        // 37 encodes to a single byte 0x25.
        var small = ByteBuffer()
        QUICVarint.write(37, to: &small)
        #expect(Array(small.readableBytesView) == [0x25])
    }
}

@Suite
struct HTTP3DatagramCodecTests {
    @Test
    func datagramRoundTripUsesQuarterStreamID() {
        let payload = ByteBuffer(string: "webtransport datagram")
        // Client-initiated bidirectional stream 8 -> quarter stream id 2.
        let encoded = HTTP3DatagramCodec.encodeDatagram(streamID: 8, payload: payload)
        var check = encoded
        #expect(QUICVarint.read(from: &check) == 2)

        let decoded = HTTP3DatagramCodec.decodeDatagram(encoded)
        #expect(decoded?.streamID == 8)
        #expect(decoded?.payload == payload)
    }

    @Test
    func datagramDecodeRejectsEmpty() {
        #expect(HTTP3DatagramCodec.decodeDatagram(ByteBuffer()) == nil)
    }

    @Test
    func capsuleRoundTrip() {
        let capsule = HTTP3DatagramCodec.Capsule(type: 0x00, value: ByteBuffer(string: "session"))
        var buffer = ByteBuffer()
        HTTP3DatagramCodec.writeCapsule(capsule, to: &buffer)
        let read = HTTP3DatagramCodec.readCapsule(from: &buffer)
        #expect(read == capsule)
        #expect(buffer.readableBytes == 0)
    }

    @Test
    func capsuleReadIsAtomicOnPartialData() {
        let capsule = HTTP3DatagramCodec.Capsule(type: 0x02, value: ByteBuffer(repeating: 0xAB, count: 300))
        var full = ByteBuffer()
        HTTP3DatagramCodec.writeCapsule(capsule, to: &full)

        // Feed only a prefix: readCapsule must return nil and not consume.
        var partial = full.getSlice(at: full.readerIndex, length: 5)!
        let before = partial.readerIndex
        #expect(HTTP3DatagramCodec.readCapsule(from: &partial) == nil)
        #expect(partial.readerIndex == before)

        // The complete buffer decodes.
        var complete = full
        #expect(HTTP3DatagramCodec.readCapsule(from: &complete) == capsule)
    }

    @Test
    func multipleCapsulesInSequence() {
        var buffer = ByteBuffer()
        let a = HTTP3DatagramCodec.Capsule(type: 1, value: ByteBuffer(string: "a"))
        let b = HTTP3DatagramCodec.Capsule(type: 2, value: ByteBuffer(string: "bb"))
        HTTP3DatagramCodec.writeCapsule(a, to: &buffer)
        HTTP3DatagramCodec.writeCapsule(b, to: &buffer)
        #expect(HTTP3DatagramCodec.readCapsule(from: &buffer) == a)
        #expect(HTTP3DatagramCodec.readCapsule(from: &buffer) == b)
        #expect(HTTP3DatagramCodec.readCapsule(from: &buffer) == nil)
    }
}
