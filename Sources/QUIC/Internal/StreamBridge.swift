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

/// Bridges a QUIC stream `Channel` into a ``QUICStream``.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
enum StreamFactory {
    /// Wraps a raw NIOQUIC stream channel. Must be called from the stream
    /// channel's initializer (i.e. on its event loop, before the channel goes
    /// active).
    ///
    /// - Parameters:
    ///   - channel: The stream channel to wrap.
    ///   - knownID: The stream ID, when the caller already has it (outbound
    ///     streams). For inbound streams pass `nil`; the ID is read from the
    ///     channel.
    ///   - localRole: Whether the local endpoint is the client or the server;
    ///     used to derive writability of unidirectional streams.
    static func makeStream(
        channel: any Channel,
        knownID: UInt64?,
        localRole: EndpointRole
    ) -> EventLoopFuture<QUICStream> {
        channel.setOption(.halfCloseOnStopSending, value: true)
            .flatMap {
                if let knownID {
                    return channel.eventLoop.makeSucceededFuture(knownID)
                }
                return channel.getOption(.quicStreamID)
            }
            .flatMapThrowing { rawID in
                // Runs on the channel's event loop.
                let id = QUICStreamID(rawValue: rawID)
                let writable = id.isBidirectional || id.initiator == localRole.streamInitiator
                let writeGate = WriteGate(writable: writable)

                let delegate = StreamBridgeDelegate(eventLoop: channel.eventLoop)
                let sequenceAndSource = QUICStream.Inbound.Producer.makeSequence(
                    elementType: ByteBuffer.self,
                    failureType: (any Error).self,
                    backPressureStrategy: .init(lowWatermark: 2, highWatermark: 16),
                    finishOnDeinit: false,
                    delegate: delegate
                )

                let handler = StreamBridgeHandler(
                    source: sequenceAndSource.source,
                    writeGate: writeGate,
                    readable: id.isBidirectional || id.initiator != localRole.streamInitiator
                )
                delegate.attach(handler: handler)
                try channel.pipeline.syncOperations.addHandler(handler)

                return QUICStream(
                    channel: channel,
                    id: id,
                    inbound: QUICStream.Inbound(producer: sequenceAndSource.sequence),
                    writeGate: writeGate
                )
            }
    }
}

/// Relays backpressure signals from the async sequence's consumer (any thread)
/// onto the channel's event loop.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class StreamBridgeDelegate: NIOAsyncSequenceProducerDelegate, Sendable {
    private let eventLoop: any EventLoop
    private let handler: Mutex<NIOLoopBound<StreamBridgeHandler>?> = Mutex(nil)

    init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    /// Must be called on the event loop, before the sequence is consumed.
    func attach(handler: StreamBridgeHandler) {
        let bound = NIOLoopBound(handler, eventLoop: self.eventLoop)
        self.handler.withLock { $0 = bound }
    }

    func produceMore() {
        let bound = self.handler.withLock { $0 }
        self.eventLoop.execute {
            bound?.value.produceMore()
        }
    }

    func didTerminate() {
        let bound = self.handler.withLock { $0 }
        self.eventLoop.execute {
            bound?.value.consumerDidTerminate()
        }
    }
}

/// Feeds inbound stream data into the async sequence and translates
/// stream-level protocol events into Swift errors and write-gate state.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
final class StreamBridgeHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum ProducingState {
        case keepProducing
        case producingPaused
        case producingPausedWithOutstandingRead
    }

    private let source: QUICStream.Inbound.Producer.Source
    private let writeGate: WriteGate
    private let readable: Bool
    private var producingState: ProducingState = .keepProducing
    private var context: ChannelHandlerContext?
    private var consumerTerminated = false

    init(source: QUICStream.Inbound.Producer.Source, writeGate: WriteGate, readable: Bool) {
        self.source = source
        self.writeGate = writeGate
        self.readable = readable
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if !self.readable {
            // Send-only stream: there will never be inbound data.
            self.source.finish()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.source.finish()
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if self.consumerTerminated {
            // Nobody is reading any more; drop the data on the floor.
            return
        }
        switch self.source.yield(buffer) {
        case .stopProducing:
            if case .keepProducing = self.producingState {
                self.producingState = .producingPaused
            }
        case .produceMore, .dropped:
            ()
        }
    }

    func read(context: ChannelHandlerContext) {
        switch self.producingState {
        case .keepProducing:
            context.read()
        case .producingPaused:
            self.producingState = .producingPausedWithOutstandingRead
        case .producingPausedWithOutstandingRead:
            ()
        }
    }

    func produceMore() {
        switch self.producingState {
        case .producingPaused:
            self.producingState = .keepProducing
        case .producingPausedWithOutstandingRead:
            self.producingState = .keepProducing
            self.context?.read()
        case .keepProducing:
            ()
        }
    }

    func consumerDidTerminate() {
        self.consumerTerminated = true
        // Resume reads so flow control keeps advancing; data is discarded in
        // channelRead.
        self.produceMore()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            // The peer sent FIN: the read side is complete.
            self.source.finish()
        case let event as NIOQUICHelpers.QUICStopSendingEvent:
            // The peer no longer wants our data.
            self.writeGate.markStopSending(code: QUICApplicationErrorCode(event.code))
        default:
            ()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        switch error {
        case let reset as NIOQUICHelpers.QUICStreamResetError:
            self.source.finish(
                QUICStreamError(code: .reset, applicationErrorCode: QUICApplicationErrorCode(reset.code))
            )
        case let stop as NIOQUICHelpers.QUICStopSendingError:
            // Only surfaced when half-close-on-stop-sending is disabled; we
            // enable it, but handle this defensively.
            self.writeGate.markStopSending(code: QUICApplicationErrorCode(stop.code))
        case let network as NetworkError:
            // In some teardown races the QUIC stack surfaces the peer's
            // RESET_STREAM as a raw transport error: either carrying the
            // application error code, or as a bare POSIX "connection reset"
            // (in which case the code is not preserved). Translate both so
            // callers always see a typed reset.
            if let rawCode = network.quicApplicationError,
                rawCode >= 0,
                let code = QUICApplicationErrorCode(rawValue: UInt64(rawCode))
            {
                self.source.finish(
                    QUICStreamError(code: .reset, applicationErrorCode: code)
                )
            } else if let domainError = network.domainSpecificError,
                domainError.domain == NetworkPOSIXError.domain,
                domainError.code == Int64(ECONNRESET)
            {
                self.source.finish(QUICStreamError(code: .reset))
            } else {
                self.source.finish(error)
            }
        default:
            self.source.finish(error)
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.writeGate.markClosed()
        self.source.finish()
        context.fireChannelInactive()
    }
}
