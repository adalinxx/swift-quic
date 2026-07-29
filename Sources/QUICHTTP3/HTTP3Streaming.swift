//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTPTypes

// Streaming HTTP/3 bodies. Unlike the collected `HTTP3Request`/`HTTP3Response`
// API, these expose the body incrementally in both directions, preserving QUIC
// flow-control backpressure (the underlying request-stream channel is read and
// written one part at a time). Suitable for large uploads/downloads, SSE, and
// gRPC-style streaming.

/// An incrementally-readable HTTP/3 body: an `AsyncSequence` of the body
/// chunks, in order, ending when the peer finishes the message.
///
/// Backed directly by the request stream, so consuming it slowly applies
/// backpressure to the sender.
public struct HTTP3IncomingBody<Part: HTTP3BodyPart>: AsyncSequence, Sendable {
    public typealias Element = ByteBuffer

    private let reader: PartReader<Part>

    init(reader: PartReader<Part>) {
        self.reader = reader
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(reader: self.reader)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let reader: PartReader<Part>

        init(reader: PartReader<Part>) {
            self.reader = reader
        }

        public mutating func next() async throws -> ByteBuffer? {
            try await self.reader.nextBodyChunk()
        }
    }
}

@available(*, unavailable)
extension HTTP3IncomingBody.AsyncIterator: Sendable {}

/// A part type (`HTTPRequestPart` / `HTTPResponsePart`) that carries a body
/// chunk. Internal plumbing for the streaming body types.
public protocol HTTP3BodyPart: Sendable {
    static func body(_ buffer: ByteBuffer) -> Self
    /// The body payload if this part is a body chunk, else `nil`.
    var bodyChunk: ByteBuffer? { get }
}

extension HTTPRequestPart: HTTP3BodyPart {
    public var bodyChunk: ByteBuffer? {
        if case .body(let buffer) = self { return buffer }
        return nil
    }
}

extension HTTPResponsePart: HTTP3BodyPart {
    public var bodyChunk: ByteBuffer? {
        if case .body(let buffer) = self { return buffer }
        return nil
    }
}

/// Serializes access to a stream's inbound iterator so a body sequence can be
/// read after the head has already been consumed. Single-consumer.
final class PartReader<Part: HTTP3BodyPart>: @unchecked Sendable {
    private let storage: NIOLockedValueBox<Storage>

    struct Storage {
        var iterator: NIOAsyncChannelInboundStream<Part>.AsyncIterator
        var finished = false
    }

    init(iterator: NIOAsyncChannelInboundStream<Part>.AsyncIterator) {
        self.storage = NIOLockedValueBox(Storage(iterator: iterator))
    }

    /// Advances to the next inbound part.
    func next() async throws -> Part? {
        // The lock only guards the iterator handoff; `next()` is awaited outside
        // the lock because the iterator is single-consumer by contract.
        var iterator = self.storage.withLockedValue { $0.iterator }
        let part = try await iterator.next()
        self.storage.withLockedValue { $0.iterator = iterator }
        return part
    }

    /// Returns the next body chunk, or `nil` at end of message. Leading
    /// non-body parts (a `.head` not yet consumed by the caller) are skipped.
    func nextBodyChunk() async throws -> ByteBuffer? {
        if self.storage.withLockedValue({ $0.finished }) { return nil }
        while let part = try await self.next() {
            if let chunk = part.bodyChunk {
                return chunk
            }
            // `.head`: skip and keep reading. `.end`: the next `next()` returns
            // nil and the loop exits.
        }
        self.storage.withLockedValue { $0.finished = true }
        return nil
    }

    /// Consumes any remaining parts so the stream can close cleanly. Best
    /// effort: stops on the first error (e.g. the peer already reset).
    func drain() async {
        while (try? await self.next()) != nil {}
        self.storage.withLockedValue { $0.finished = true }
    }
}
