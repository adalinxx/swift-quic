//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// A self-contained demo: starts a QUIC echo server on localhost with an
// ephemeral self-signed certificate, connects a client to it, exchanges a
// stream echo and a datagram echo, then shuts down.
//
// Run with: swift run quic-echo

import Logging
import QUIC

let alpn = ["quic-echo-demo"]

// 1. Server: ephemeral self-signed identity, echo every stream and datagram.
let selfSigned = try QUICIdentity.selfSigned()
let serverConfiguration = QUICServer.Configuration(
    identity: selfSigned.identity,
    applicationProtocols: alpn
)

let server = try await QUICServer.bind(host: "127.0.0.1", configuration: serverConfiguration)
print("server listening on \(server.localAddress)")

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await server.run { connection in
            await withDiscardingTaskGroup { group in
                group.addTask {
                    for await datagram in connection.datagrams {
                        try? await connection.sendDatagram(datagram)
                    }
                }
                for await stream in connection.incomingStreams {
                    group.addTask {
                        do {
                            for try await chunk in stream.inbound {
                                try await stream.send(chunk)
                            }
                            try await stream.finish()
                        } catch {}
                    }
                }
            }
        }
    }

    // 2. Client: trust the server's certificate, echo once over a stream and
    //    once as a datagram.
    var clientConfiguration = QUICClient.Configuration(applicationProtocols: alpn)
    clientConfiguration.trustRoots = .certificates([selfSigned.certificate])

    try await QUICClient.withConnection(
        to: "127.0.0.1",
        port: server.localAddress.port!,
        configuration: clientConfiguration
    ) { connection in
        let stream = try await connection.openBidirectionalStream()
        try await stream.send("hello over a stream")
        try await stream.finish()
        let reply = try await stream.collect(upTo: 1024)
        print("stream echo: \(String(buffer: reply))")

        try await connection.sendDatagram(ByteBuffer(string: "hello as a datagram"))
        var datagrams = connection.datagrams.makeAsyncIterator()
        if let echoed = await datagrams.next() {
            print("datagram echo: \(String(buffer: echoed))")
        }
    }

    group.cancelAll()
}

await server.close()
print("done")
