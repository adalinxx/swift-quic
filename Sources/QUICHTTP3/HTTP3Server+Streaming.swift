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
extension HTTP3Server {
    /// An inbound request whose body is read incrementally.
    public struct StreamingRequest: Sendable {
        /// The request head (method, path, scheme, authority, headers).
        public let head: HTTPRequest
        /// The request body chunks, streamed in order.
        public let body: HTTP3IncomingBody<HTTPRequestPart>

        /// The request method.
        public var method: HTTPRequest.Method { self.head.method }
        /// The `:path` pseudo-header.
        public var path: String { self.head.path ?? "" }
    }

    /// Writes a streaming response: send the head once, then zero or more body
    /// chunks. The message is finished automatically when the handler returns.
    public struct ResponseWriter: Sendable {
        private let writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
        private let pendingTrailers: NIOLockedValueBox<HTTPFields>

        init(writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>, pendingTrailers: NIOLockedValueBox<HTTPFields>) {
            self.writer = writer
            self.pendingTrailers = pendingTrailers
        }

        /// Sets trailer fields to send after the body when the response ends.
        public func setTrailers(_ trailers: HTTPFields) {
            self.pendingTrailers.withLockedValue { $0 = trailers }
        }

        /// Sends the response head. Call once, before any body chunk.
        public func writeHead(_ response: HTTPResponse) async throws {
            try await self.writer.write(.head(response))
        }

        /// Sends the head built from a status and header fields.
        public func writeHead(status: HTTPResponse.Status, headerFields: HTTPFields = [:]) async throws {
            try await self.writeHead(HTTPResponse(status: status, headerFields: headerFields))
        }

        /// Sends a body chunk.
        public func write(_ buffer: ByteBuffer) async throws {
            try await self.writer.write(.body(buffer))
        }

        /// Sends the UTF-8 bytes of `string` as a body chunk.
        public func write(_ string: String) async throws {
            try await self.write(ByteBuffer(string: string))
        }
    }

    /// Serves requests with streaming bodies until the server shuts down.
    ///
    /// `handler` receives each request's head plus a body sequence it can read
    /// incrementally, and a ``ResponseWriter`` for producing the response
    /// incrementally. This is the streaming counterpart to ``run(_:)`` and is
    /// the right choice for large uploads/downloads, server-sent events, and
    /// other long-lived response bodies.
    ///
    /// ```swift
    /// try await server.run(streaming: { request, response in
    ///     try await response.writeHead(status: .ok)
    ///     for try await chunk in request.body {
    ///         try await response.write(chunk)   // echo, without buffering
    ///     }
    /// })
    /// ```
    public func run(
        streaming handler: @escaping @Sendable (StreamingRequest, ResponseWriter) async throws -> Void
    ) async throws {
        try await withThrowingDiscardingTaskGroup { connectionGroup in
            for try await connection in self.multiplexer.inboundConnections {
                connectionGroup.addTask {
                    await withDiscardingTaskGroup { streamGroup in
                        for await stream in connection.inboundStreams {
                            streamGroup.addTask {
                                await Self.handleStreaming(stream: stream, handler: handler)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func handleStreaming(
        stream: RequestStream,
        handler: @Sendable (StreamingRequest, ResponseWriter) async throws -> Void
    ) async {
        do {
            try await stream.asyncChannel.executeThenClose { inbound, outbound in
                let reader = PartReader<HTTPRequestPart>(iterator: inbound.makeAsyncIterator())
                // The first part must be the head.
                guard let first = try await reader.next(), case .head(let head) = first else {
                    return
                }
                let request = StreamingRequest(head: head, body: HTTP3IncomingBody(reader: reader))
                let pendingTrailers = NIOLockedValueBox<HTTPFields>([:])
                let writer = ResponseWriter(writer: outbound, pendingTrailers: pendingTrailers)
                try await handler(request, writer)
                // Drain any unread request body so closing the stream doesn't
                // reset the peer mid-response (e.g. a handler that ignores the
                // request body).
                await reader.drain()
                let trailers = pendingTrailers.withLockedValue { $0 }
                try await outbound.write(.end(trailers.isEmpty ? nil : trailers))
                outbound.finish()
            }
        } catch {
            // The peer reset the stream or the connection went away.
        }
    }
}
