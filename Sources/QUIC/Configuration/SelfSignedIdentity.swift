//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOCore
import SwiftASN1
public import X509

extension QUICIdentity {
    /// Generates an ephemeral self-signed identity, entirely in memory.
    ///
    /// This is intended for development and testing: pair it on the client
    /// side with ``QUICTrustRoots/certificates(_:)`` using
    /// ``QUICSelfSignedIdentity/certificate``.
    ///
    /// - Parameters:
    ///   - commonName: The certificate's common name.
    ///   - dnsNames: DNS subject alternative names.
    ///   - ipAddresses: IP address subject alternative names (IPv4 or IPv6).
    ///   - validFor: Certificate lifetime from now.
    public static func selfSigned(
        commonName: String = "localhost",
        dnsNames: [String] = ["localhost"],
        ipAddresses: [String] = ["127.0.0.1", "::1"],
        validFor: Duration = .seconds(60 * 60 * 24)
    ) throws -> QUICSelfSignedIdentity {
        try QUICSelfSignedIdentity(
            commonName: commonName,
            dnsNames: dnsNames,
            ipAddresses: ipAddresses,
            validFor: validFor
        )
    }
}

/// A freshly-generated self-signed certificate and its private key.
///
/// Use ``identity`` to configure a server and ``certificate`` as a trust root
/// on clients:
///
/// ```swift
/// let selfSigned = try QUICIdentity.selfSigned()
/// var serverConfig = QUICServer.Configuration(
///     identity: selfSigned.identity,
///     applicationProtocols: ["my-proto"]
/// )
/// var clientConfig = QUICClient.Configuration(applicationProtocols: ["my-proto"])
/// clientConfig.trustRoots = .certificates([selfSigned.certificate])
/// ```
public struct QUICSelfSignedIdentity: Sendable {
    /// The generated self-signed certificate.
    public let certificate: Certificate

    /// The private key matching ``certificate``.
    public let privateKey: Certificate.PrivateKey

    /// The identity to install in a ``QUICServer/Configuration``.
    public var identity: QUICIdentity {
        .certificates([self.certificate], privateKey: self.privateKey)
    }

    init(
        commonName: String,
        dnsNames: [String],
        ipAddresses: [String],
        validFor: Duration
    ) throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName {
            CommonName(commonName)
        }

        var sanElements: [SubjectAlternativeNames.Element] = []
        for dns in dnsNames {
            sanElements.append(.dnsName(dns))
        }
        for ip in ipAddresses {
            if let bytes = Self.rawIPAddressBytes(ip) {
                sanElements.append(.ipAddress(ASN1OctetString(contentBytes: ArraySlice(bytes))))
            } else {
                throw QUICConfigurationError("'\(ip)' is not a valid IPv4 or IPv6 address")
            }
        }

        let now = Date()
        let seconds = TimeInterval(validFor.components.seconds)
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            KeyUsage(digitalSignature: true, keyCertSign: true)
            try ExtendedKeyUsage([.serverAuth, .clientAuth])
            SubjectAlternativeNames(sanElements)
        }

        self.certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(seconds),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: key
        )
        self.privateKey = key
    }

    /// Parses an IPv4 or IPv6 literal into its raw network-order bytes.
    static func rawIPAddressBytes(_ address: String) -> [UInt8]? {
        guard let parsed = try? SocketAddress(ipAddress: address, port: 0) else {
            return nil
        }
        switch parsed {
        case .v4(let v4):
            return withUnsafeBytes(of: v4.address.sin_addr) { Array($0) }
        case .v6(let v6):
            return withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
        default:
            return nil
        }
    }
}
