//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import HTTPTypes
public import struct NIOCore.ByteBuffer

/// An HTTP/3 request with a fully-buffered body.
///
/// This is the convenience shape for the common request/response exchange.
/// (Streaming bodies are a planned addition — see ROADMAP.)
public struct HTTP3Request: Sendable {
    /// The request method (`.get`, `.post`, …).
    public var method: HTTPRequest.Method
    /// The `:path` pseudo-header, e.g. `/index.html`.
    public var path: String
    /// The `:scheme` pseudo-header. Defaults to `https`.
    public var scheme: String
    /// The `:authority` pseudo-header (host[:port]).
    public var authority: String?
    /// Additional header fields.
    public var headerFields: HTTPFields
    /// The request body, if any.
    public var body: ByteBuffer?

    /// Creates an HTTP/3 request.
    public init(
        method: HTTPRequest.Method = .get,
        path: String = "/",
        scheme: String = "https",
        authority: String? = nil,
        headerFields: HTTPFields = [:],
        body: ByteBuffer? = nil
    ) {
        self.method = method
        self.path = path
        self.scheme = scheme
        self.authority = authority
        self.headerFields = headerFields
        self.body = body
    }

    /// The underlying `HTTPRequest` (pseudo-headers + fields).
    var httpRequest: HTTPRequest {
        HTTPRequest(
            method: self.method,
            scheme: self.scheme,
            authority: self.authority,
            path: self.path,
            headerFields: self.headerFields
        )
    }
}

/// An HTTP/3 response with a fully-buffered body.
public struct HTTP3Response: Sendable {
    /// The response status (`.ok`, `.notFound`, …).
    public var status: HTTPResponse.Status
    /// Additional header fields.
    public var headerFields: HTTPFields
    /// The response body.
    public var body: ByteBuffer

    /// Creates an HTTP/3 response.
    public init(
        status: HTTPResponse.Status = .ok,
        headerFields: HTTPFields = [:],
        body: ByteBuffer = ByteBuffer()
    ) {
        self.status = status
        self.headerFields = headerFields
        self.body = body
    }

    /// Creates a response with a UTF-8 string body.
    public init(status: HTTPResponse.Status = .ok, headerFields: HTTPFields = [:], string: String) {
        self.init(status: status, headerFields: headerFields, body: ByteBuffer(string: string))
    }

    /// The underlying `HTTPResponse`.
    var httpResponse: HTTPResponse {
        HTTPResponse(status: self.status, headerFields: self.headerFields)
    }
}

/// An inbound HTTP/3 request as seen by a server handler: the head plus its
/// fully-collected body.
public struct HTTP3ServerRequest: Sendable {
    /// The request head (method, path, scheme, authority, headers).
    public let head: HTTPRequest
    /// The collected request body.
    public let body: ByteBuffer

    /// The request method.
    public var method: HTTPRequest.Method { self.head.method }
    /// The `:path` pseudo-header.
    public var path: String { self.head.path ?? "" }
    /// The header fields.
    public var headerFields: HTTPFields { self.head.headerFields }

    init(head: HTTPRequest, body: ByteBuffer) {
        self.head = head
        self.body = body
    }
}

/// Errors surfaced by the HTTP/3 layer.
public struct HTTP3ClientError: Error, Hashable, Sendable, CustomStringConvertible {
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        enum Base: Hashable, Sendable {
            case malformedResponse
            case responseTooLarge
            case connectionClosed
        }
        var base: Base
        /// The peer's response was missing a status or otherwise malformed.
        public static let malformedResponse = Code(base: .malformedResponse)
        /// The response body exceeded the caller's limit.
        public static let responseTooLarge = Code(base: .responseTooLarge)
        /// The connection closed before the response completed.
        public static let connectionClosed = Code(base: .connectionClosed)

        public var description: String {
            switch self.base {
            case .malformedResponse: return "malformedResponse"
            case .responseTooLarge: return "responseTooLarge"
            case .connectionClosed: return "connectionClosed"
            }
        }
    }

    public var code: Code
    public init(code: Code) { self.code = code }
    public var description: String { "HTTP3ClientError.\(self.code)" }
}
