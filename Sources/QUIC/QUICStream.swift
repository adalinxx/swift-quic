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
import NIOQUICHelpers
import Synchronization

@_spi(ProtocolProvider) import SwiftNetwork

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A single QUIC stream.
///
/// Read from the stream by iterating ``inbound``; write to it with
/// ``send(_:)-(ByteBuffer)`` and signal the end of your data with ``finish()``.
///
/// ```swift
/// let stream = try await connection.openBidirectionalStream()
/// try await stream.send(ByteBuffer(string: "hello"))
/// try await stream.finish()
/// for try await chunk in stream.inbound {
///     print(String(buffer: chunk))
/// }
/// ```
///
/// Streams are cheap: open one per request/response exchange rather than
/// multiplexing by hand.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public final class QUICStream: Sendable {
    /// This stream's identifier within its connection.
    public let id: QUICStreamID

    /// The bytes received from the peer, delivered with flow-control-aware
    /// backpressure. The sequence ends when the peer finishes the stream, and
    /// throws ``QUICStreamError`` if the peer resets it.
    public let inbound: Inbound

    let channel: any Channel
    private let writeGate: WriteGate

    init(channel: any Channel, id: QUICStreamID, inbound: Inbound, writeGate: WriteGate) {
        self.channel = channel
        self.id = id
        self.inbound = inbound
        self.writeGate = writeGate
    }

    deinit {
        // Safety net: abort anything still open if the handle is dropped.
        self.channel.close(promise: nil)
    }

    /// Whether data can be sent on this stream (it is bidirectional or a
    /// locally-initiated unidirectional stream, and ``finish()`` has not been
    /// called).
    public var isWritable: Bool {
        self.writeGate.isWritable
    }

    /// Sends the given bytes on the stream, applying backpressure from QUIC
    /// flow control.
    public func send(_ buffer: ByteBuffer) async throws {
        try self.writeGate.checkSendable()
        do {
            let promise = self.channel.eventLoop.makePromise(of: Void.self)
            self.channel.writeAndFlush(buffer, promise: promise)
            try await withCancellableWait(promise.futureResult)
        } catch {
            throw Self.mapWriteError(error)
        }
    }

    /// Translates transport-level write failures into typed stream errors.
    static func mapWriteError(_ error: any Error) -> any Error {
        if let channelError = error as? ChannelError, channelError == .ioOnClosedChannel {
            return QUICStreamError(code: .closed)
        }
        // A pending write can fail with the raw transport error when the peer
        // resets the stream: either carrying the RESET_STREAM application
        // error code, or as a bare POSIX "connection reset" in some teardown
        // races (where the code is not preserved).
        if let network = error as? NetworkError {
            if let rawCode = network.quicApplicationError,
                rawCode >= 0,
                let code = QUICApplicationErrorCode(rawValue: UInt64(rawCode))
            {
                return QUICStreamError(code: .reset, applicationErrorCode: code)
            }
            if let domainError = network.domainSpecificError,
                domainError.domain == NetworkPOSIXError.domain,
                domainError.code == Int64(ECONNRESET)
            {
                return QUICStreamError(code: .reset)
            }
        }
        return error
    }

    /// Sends the UTF-8 bytes of the given string on the stream.
    public func send(_ string: String) async throws {
        try await self.send(ByteBuffer(string: string))
    }

    /// Sends the given bytes on the stream.
    public func send(contentsOf bytes: some Sequence<UInt8> & Sendable) async throws {
        try await self.send(ByteBuffer(bytes: bytes))
    }

    /// Signals that no more data will be sent on this stream (sends a FIN).
    ///
    /// The receive side is unaffected: you can keep reading ``inbound`` after
    /// finishing. Finishing an already-finished stream is a no-op.
    public func finish() async throws {
        guard self.writeGate.markFinished() else { return }
        do {
            try await self.channel.close(mode: .output).get()
        } catch let error as ChannelError where error == .alreadyClosed || error == .ioOnClosedChannel {
            // Fully closing a stream implies the output is closed too.
        }
    }

    /// Abruptly terminates the send side of the stream (sends `RESET_STREAM`).
    ///
    /// Any data that was written but not yet delivered may be discarded.
    public func reset(errorCode: QUICApplicationErrorCode) {
        self.writeGate.markClosed()
        self.channel.pipeline.triggerUserOutboundEvent(
            QUICResetStreamEvent(code: errorCode.helperCode),
            promise: nil
        )
    }

    /// Asks the peer to stop sending on this stream (sends `STOP_SENDING`).
    ///
    /// ``inbound`` will end after the peer confirms.
    public func stopSending(errorCode: QUICApplicationErrorCode) {
        self.channel.pipeline.triggerUserOutboundEvent(
            QUICStopSendingEvent(code: errorCode.helperCode),
            promise: nil
        )
    }

    /// Closes the stream in both directions immediately.
    ///
    /// Prefer ``finish()`` plus draining ``inbound`` for a graceful end of
    /// stream; use `close()` to abandon the stream early.
    public func close() async {
        self.writeGate.markClosed()
        try? await self.channel.close(mode: .all).get()
    }

    /// Reads the entire remainder of ``inbound`` into a single buffer.
    ///
    /// - Parameter maxBytes: An upper bound on the bytes to accumulate. If the
    ///   peer sends more, a ``QUICStreamError`` with code
    ///   ``QUICStreamError/Code-swift.struct/closed`` is *not* thrown; instead
    ///   this throws `QUICStreamCollectError.tooManyBytes`.
    public func collect(upTo maxBytes: Int) async throws -> ByteBuffer {
        var accumulator = ByteBuffer()
        for try await var chunk in self.inbound {
            guard accumulator.readableBytes + chunk.readableBytes <= maxBytes else {
                throw QUICStreamCollectError.tooManyBytes(limit: maxBytes)
            }
            accumulator.writeBuffer(&chunk)
        }
        return accumulator
    }

    /// The bytes received on a ``QUICStream``.
    public struct Inbound: AsyncSequence, Sendable {
        public typealias Element = ByteBuffer

        typealias Producer = NIOThrowingAsyncSequenceProducer<
            ByteBuffer, any Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
            StreamBridgeDelegate
        >

        private let producer: Producer

        init(producer: Producer) {
            self.producer = producer
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.producer.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            private var iterator: Producer.AsyncIterator

            init(iterator: Producer.AsyncIterator) {
                self.iterator = iterator
            }

            public mutating func next() async throws -> ByteBuffer? {
                try await self.iterator.next()
            }
        }
    }
}

@available(*, unavailable)
extension QUICStream.Inbound.AsyncIterator: Sendable {}

/// Thrown by ``QUICStream/collect(upTo:)`` when the peer sends more data than
/// the caller allowed for.
public enum QUICStreamCollectError: Error, Hashable, Sendable {
    case tooManyBytes(limit: Int)
}

/// Tracks whether the local side may still send on a stream.
final class WriteGate: Sendable {
    enum State: Sendable {
        case open
        case finished
        case stopSendingReceived(QUICApplicationErrorCode)
        case closed
        case neverWritable
    }

    private let state: Mutex<State>

    init(writable: Bool) {
        self.state = Mutex(writable ? .open : .neverWritable)
    }

    var isWritable: Bool {
        self.state.withLock {
            if case .open = $0 { return true }
            return false
        }
    }

    func checkSendable() throws {
        try self.state.withLock { state in
            switch state {
            case .open:
                return
            case .finished:
                throw QUICStreamError(code: .notWritable)
            case .stopSendingReceived(let code):
                throw QUICStreamError(code: .stopSendingReceived, applicationErrorCode: code)
            case .closed:
                throw QUICStreamError(code: .closed)
            case .neverWritable:
                throw QUICStreamError(code: .notWritable)
            }
        }
    }

    /// Returns `true` if this call transitioned the gate to `.finished`.
    func markFinished() -> Bool {
        self.state.withLock { state in
            if case .open = state {
                state = .finished
                return true
            }
            return false
        }
    }

    func markStopSending(code: QUICApplicationErrorCode) {
        self.state.withLock { state in
            if case .open = state {
                state = .stopSendingReceived(code)
            }
        }
    }

    func markClosed() {
        self.state.withLock { $0 = .closed }
    }
}
