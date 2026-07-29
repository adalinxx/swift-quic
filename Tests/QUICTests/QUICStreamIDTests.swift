//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Testing

@testable import QUIC

@Suite
struct QUICStreamIDTests {
    @Test
    func bitZeroEncodesInitiator() {
        #expect(QUICStreamID(rawValue: 0).initiator == .client)
        #expect(QUICStreamID(rawValue: 1).initiator == .server)
        #expect(QUICStreamID(rawValue: 2).initiator == .client)
        #expect(QUICStreamID(rawValue: 3).initiator == .server)
        #expect(QUICStreamID(rawValue: 4).initiator == .client)
        #expect(QUICStreamID(rawValue: 1000).initiator == .client)
        #expect(QUICStreamID(rawValue: 1001).initiator == .server)
    }

    @Test
    func bitOneEncodesDirection() {
        #expect(QUICStreamID(rawValue: 0).isBidirectional)
        #expect(QUICStreamID(rawValue: 1).isBidirectional)
        #expect(QUICStreamID(rawValue: 2).isUnidirectional)
        #expect(QUICStreamID(rawValue: 3).isUnidirectional)
        #expect(QUICStreamID(rawValue: 4).isBidirectional)
        #expect(QUICStreamID(rawValue: 6).isUnidirectional)
    }

    @Test
    func comparableOrdersByRawValue() {
        #expect(QUICStreamID(rawValue: 0) < QUICStreamID(rawValue: 4))
        #expect(!(QUICStreamID(rawValue: 4) < QUICStreamID(rawValue: 4)))
    }

    @Test
    func descriptionIsHumanReadable() {
        let id = QUICStreamID(rawValue: 2)
        #expect(id.description.contains("2"))
        #expect(id.description.contains("client"))
        #expect(id.description.contains("unidirectional"))
    }
}

@Suite
struct QUICApplicationErrorCodeTests {
    @Test
    func integerLiteralAndRawValue() {
        let code: QUICApplicationErrorCode = 42
        #expect(code.rawValue == 42)
        #expect(QUICApplicationErrorCode.noError.rawValue == 0)
    }

    @Test
    func rejectsValuesBeyondVarIntRange() {
        #expect(QUICApplicationErrorCode(rawValue: QUICApplicationErrorCode.maxValue) != nil)
        #expect(QUICApplicationErrorCode(rawValue: QUICApplicationErrorCode.maxValue + 1) == nil)
    }

    @Test
    func roundTripsThroughHelperType() {
        let code: QUICApplicationErrorCode = 7
        #expect(QUICApplicationErrorCode(code.helperCode) == code)
    }
}

@Suite
struct QUICErrorTests {
    @Test
    func streamErrorDescriptionsIncludeCode() {
        let error = QUICStreamError(code: .reset, applicationErrorCode: 9)
        #expect(error.description.contains("reset"))
        #expect(error.description.contains("9"))
        #expect(QUICStreamError(code: .closed).description.contains("closed"))
    }

    @Test
    func streamErrorEquality() {
        #expect(QUICStreamError(code: .reset, applicationErrorCode: 1) == QUICStreamError(code: .reset, applicationErrorCode: 1))
        #expect(QUICStreamError(code: .reset, applicationErrorCode: 1) != QUICStreamError(code: .reset, applicationErrorCode: 2))
        #expect(QUICStreamError(code: .reset) != QUICStreamError(code: .closed))
    }

    @Test
    func connectionErrorDescription() {
        let error = QUICConnectionError(code: .datagramTooLarge, message: "too big")
        #expect(error.description.contains("datagramTooLarge"))
        #expect(error.description.contains("too big"))
    }
}

@Suite
struct WriteGateTests {
    @Test
    func openGateAllowsSending() throws {
        let gate = WriteGate(writable: true)
        #expect(gate.isWritable)
        try gate.checkSendable()
    }

    @Test
    func neverWritableGateRejects() {
        let gate = WriteGate(writable: false)
        #expect(!gate.isWritable)
        #expect(throws: QUICStreamError(code: .notWritable)) {
            try gate.checkSendable()
        }
    }

    @Test
    func finishingIsOneShot() {
        let gate = WriteGate(writable: true)
        #expect(gate.markFinished())
        #expect(!gate.markFinished())
        #expect(throws: QUICStreamError(code: .notWritable)) {
            try gate.checkSendable()
        }
    }

    @Test
    func stopSendingCarriesCode() {
        let gate = WriteGate(writable: true)
        gate.markStopSending(code: 21)
        #expect(throws: QUICStreamError(code: .stopSendingReceived, applicationErrorCode: 21)) {
            try gate.checkSendable()
        }
    }

    @Test
    func closedWinsOverLaterTransitions() {
        let gate = WriteGate(writable: true)
        gate.markClosed()
        gate.markStopSending(code: 3)
        #expect(throws: QUICStreamError(code: .closed)) {
            try gate.checkSendable()
        }
    }
}
