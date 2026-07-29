//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// An error affecting a single QUIC stream.
public struct QUICStreamError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The kind of stream error.
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        enum Base: Hashable, Sendable {
            case reset
            case stopSendingReceived
            case notWritable
            case closed
        }

        var base: Base

        /// The peer aborted the stream with a `RESET_STREAM` frame.
        public static let reset = Code(base: .reset)
        /// The peer asked us to stop sending with a `STOP_SENDING` frame.
        public static let stopSendingReceived = Code(base: .stopSendingReceived)
        /// The stream cannot be written to (for example, it is a receive-only
        /// unidirectional stream, or ``QUICStream/finish()`` was already called).
        public static let notWritable = Code(base: .notWritable)
        /// The stream is already closed.
        public static let closed = Code(base: .closed)

        public var description: String {
            switch self.base {
            case .reset: return "reset"
            case .stopSendingReceived: return "stopSendingReceived"
            case .notWritable: return "notWritable"
            case .closed: return "closed"
            }
        }
    }

    /// The kind of error that occurred.
    public var code: Code

    /// The application error code carried by the peer's `RESET_STREAM` or
    /// `STOP_SENDING` frame, when applicable.
    public var applicationErrorCode: QUICApplicationErrorCode?

    /// Creates a stream error.
    public init(code: Code, applicationErrorCode: QUICApplicationErrorCode? = nil) {
        self.code = code
        self.applicationErrorCode = applicationErrorCode
    }

    public var description: String {
        if let applicationErrorCode {
            return "QUICStreamError.\(self.code) (application error code: \(applicationErrorCode))"
        }
        return "QUICStreamError.\(self.code)"
    }
}

/// An error affecting an entire QUIC connection.
public struct QUICConnectionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The kind of connection error.
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        enum Base: Hashable, Sendable {
            case closed
            case datagramsNotSupportedByPeer
            case datagramTooLarge
            case connectFailed
        }

        var base: Base

        /// The connection is closed.
        public static let closed = Code(base: .closed)
        /// The peer does not accept QUIC datagrams (RFC 9221).
        public static let datagramsNotSupportedByPeer = Code(base: .datagramsNotSupportedByPeer)
        /// The datagram exceeds the peer's advertised maximum datagram frame size.
        public static let datagramTooLarge = Code(base: .datagramTooLarge)
        /// The connection could not be established.
        public static let connectFailed = Code(base: .connectFailed)

        public var description: String {
            switch self.base {
            case .closed: return "closed"
            case .datagramsNotSupportedByPeer: return "datagramsNotSupportedByPeer"
            case .datagramTooLarge: return "datagramTooLarge"
            case .connectFailed: return "connectFailed"
            }
        }
    }

    /// The kind of error that occurred.
    public var code: Code

    /// Additional human-readable context.
    public var message: String?

    /// Creates a connection error.
    public init(code: Code, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public var description: String {
        if let message {
            return "QUICConnectionError.\(self.code): \(message)"
        }
        return "QUICConnectionError.\(self.code)"
    }
}

/// An error in the local configuration, thrown before any network activity.
public struct QUICConfigurationError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A description of the configuration problem.
    public var message: String

    /// Creates a configuration error.
    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        "QUICConfigurationError: \(self.message)"
    }
}
