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
import NIOCore
import NIOHTTPTypes
import NIOConcurrencyHelpers
@_spi(HTTP3AsyncInterface) import NIOHTTP3

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
extension HTTP3Client.Connection {
    /// Writes a streaming request body: zero or more chunks followed by
    /// ``finish()``. The request head is sent before the body closure runs.
    public struct RequestBodyWriter: Sendable {
        private let writer: NIOAsyncChannelOutboundWriter<HTTPRequestPart>

        init(writer: NIOAsyncChannelOutboundWriter<HTTPRequestPart>) {
            self.writer = writer
        }

        /// Sends a request body chunk.
        public func write(_ buffer: ByteBuffer) async throws {
            try await self.writer.write(.body(buffer))
        }

        /// Sends the UTF-8 bytes of `string` as a request body chunk.
        public func write(_ string: String) async throws {
            try await self.write(ByteBuffer(string: string))
        }

        /// Signals the end of the request body.
        public func finish() {
            self.writer.finish()
        }
    }

    /// A response whose head is read on demand and whose body is read
    /// incrementally.
    ///
    /// Call ``head()`` to await the response head (status + headers) — this is
    /// what lets the server respond *after* consuming a streamed request body,
    /// without deadlocking. Then read ``body``.
    public struct StreamingResponse: Sendable {
        let reader: ResponseReader

        /// Awaits and returns the response head. Cached after the first call;
        /// call before reading ``body``.
        public func head() async throws -> HTTPResponse {
            try await self.reader.head()
        }

        /// The response body chunks, streamed in order. Read after ``head()``.
        public var body: HTTP3IncomingBody<HTTPResponsePart> {
            HTTP3IncomingBody(reader: self.reader.partReader)
        }
    }

    /// Lazily reads the response head from the shared part reader.
    final class ResponseReader: @unchecked Sendable {
        let partReader: PartReader<HTTPResponsePart>
        private let cachedHead = NIOLockedValueBox<HTTPResponse?>(nil)

        init(partReader: PartReader<HTTPResponsePart>) {
            self.partReader = partReader
        }

        func head() async throws -> HTTPResponse {
            if let cached = self.cachedHead.withLockedValue({ $0 }) { return cached }
            guard let first = try await self.partReader.next(), case .head(let head) = first else {
                throw HTTP3ClientError(code: .malformedResponse)
            }
            self.cachedHead.withLockedValue { $0 = head }
            return head
        }
    }

    /// Issues a request with streaming bodies in both directions.
    ///
    /// The request head is sent first; then `body` runs with a
    /// ``RequestBodyWriter`` (write request body chunks, then `finish()`) and a
    /// ``StreamingResponse`` (the response head, plus its body as an
    /// `AsyncSequence` you read incrementally).
    ///
    /// ```swift
    /// try await connection.withStreamingRequest(HTTPRequest(method: .post, ...)) { writer, response in
    ///     try await writer.write(chunk)
    ///     writer.finish()
    ///     for try await responseChunk in response.body { ... }
    /// }
    /// ```
    public func withStreamingRequest<Result: Sendable>(
        _ head: HTTPRequest,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (RequestBodyWriter, StreamingResponse) async throws -> Result
    ) async throws -> Result {
        var head = head
        if head.authority == nil {
            head.authority = self.authority
        }

        let stream = try await self.underlying.concurrencyView.createRequestStream {
            parameters -> EventLoopFuture<NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>> in
            parameters.channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                    wrappingChannelSynchronously: parameters.channel,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
            }
        }

        return try await stream.executeThenClose { inbound, outbound in
            try await outbound.write(.head(head))
            let writer = RequestBodyWriter(writer: outbound)
            let reader = PartReader<HTTPResponsePart>(iterator: inbound.makeAsyncIterator())
            let response = StreamingResponse(reader: ResponseReader(partReader: reader))
            let result = try await body(writer, response)
            // Drain any unread response body so the stream closes cleanly
            // instead of resetting the peer.
            await reader.drain()
            return result
        }
    }
}
