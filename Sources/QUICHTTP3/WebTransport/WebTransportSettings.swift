//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTP3

/// Builds the HTTP/3 SETTINGS a WebTransport endpoint advertises.
enum WebTransportSettings {
    private static func setting(_ id: UInt64, _ value: UInt64) -> HTTP3Setting {
        HTTP3Setting(identifier: HTTP3Setting.Identifier(extensionSetting: id)!, value: value)
    }

    /// Server settings: enable HTTP/3 datagrams, extended CONNECT, and advertise
    /// the WebTransport session limit.
    static func serverSettings(maxSessions: UInt64) throws -> HTTP3Settings {
        try HTTP3Settings(parsing: [
            setting(HTTP3DatagramCodec.h3DatagramSettingID, 1),
            setting(HTTP3DatagramCodec.enableConnectProtocolSettingID, 1),
            setting(HTTP3DatagramCodec.webTransportMaxSessionsSettingID, maxSessions),
        ])
    }

    /// Client settings: enable HTTP/3 datagrams.
    static func clientSettings() throws -> HTTP3Settings {
        try HTTP3Settings(parsing: [
            setting(HTTP3DatagramCodec.h3DatagramSettingID, 1)
        ])
    }
}
