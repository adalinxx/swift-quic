//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import X509

/// The TLS identity a QUIC server (or, in the future, a client performing
/// mutual TLS) presents to its peers.
public struct QUICIdentity: Sendable {
    enum Backing: Sendable {
        case certificateFiles(chainPEMPath: String, privateKeyPEMPath: String)
        case certificates(chain: [Certificate], privateKey: Certificate.PrivateKey)
        case rawPublicKeyFiles(publicKeyDERPath: String, privateKeyDERPath: String)
    }

    var backing: Backing

    /// An identity backed by PEM files on disk.
    ///
    /// - Parameters:
    ///   - certificateChainPEMFile: Path to a PEM file containing the leaf
    ///     certificate followed by any intermediates.
    ///   - privateKeyPEMFile: Path to a PEM file containing the leaf's private key.
    public static func certificateChain(
        pemFile certificateChainPEMFile: String,
        privateKeyPEMFile: String
    ) -> QUICIdentity {
        QUICIdentity(
            backing: .certificateFiles(
                chainPEMPath: certificateChainPEMFile,
                privateKeyPEMPath: privateKeyPEMFile
            )
        )
    }

    /// An identity backed by in-memory certificates. No files are touched.
    ///
    /// - Parameters:
    ///   - chain: The leaf certificate followed by any intermediates.
    ///   - privateKey: The private key matching the leaf certificate.
    public static func certificates(
        _ chain: [Certificate],
        privateKey: Certificate.PrivateKey
    ) -> QUICIdentity {
        QUICIdentity(backing: .certificates(chain: chain, privateKey: privateKey))
    }

    /// An identity using TLS raw public keys (RFC 7250) instead of X.509
    /// certificates.
    ///
    /// - Parameters:
    ///   - publicKeyDERFile: Path to the P-256 public key in DER form.
    ///   - privateKeyDERFile: Path to the P-256 private key in DER form.
    public static func rawPublicKey(
        publicKeyDERFile: String,
        privateKeyDERFile: String
    ) -> QUICIdentity {
        QUICIdentity(
            backing: .rawPublicKeyFiles(
                publicKeyDERPath: publicKeyDERFile,
                privateKeyDERPath: privateKeyDERFile
            )
        )
    }
}

/// The roots of trust a QUIC client uses to verify the server's certificate.
public struct QUICTrustRoots: Sendable {
    enum Backing: Sendable {
        case system
        case pemFile(String)
        case certificates([Certificate])
        case rawPublicKeyDERFile(String)
    }

    var backing: Backing

    /// Use the platform's default trust store. This is the right choice when
    /// connecting to servers with publicly-issued certificates.
    public static let system = QUICTrustRoots(backing: .system)

    /// Trust exactly the certificates in the given PEM file (replaces the
    /// system trust store).
    public static func pemFile(_ path: String) -> QUICTrustRoots {
        QUICTrustRoots(backing: .pemFile(path))
    }

    /// Trust exactly the given certificates (replaces the system trust store).
    public static func certificates(_ certificates: [Certificate]) -> QUICTrustRoots {
        QUICTrustRoots(backing: .certificates(certificates))
    }

    /// Trust a single TLS raw public key (RFC 7250) in DER form instead of an
    /// X.509 chain.
    public static func rawPublicKey(derFile path: String) -> QUICTrustRoots {
        QUICTrustRoots(backing: .rawPublicKeyDERFile(path))
    }
}

/// How thoroughly a client verifies the server's certificate.
public struct QUICCertificateVerification: Hashable, Sendable {
    enum Backing: Hashable, Sendable {
        case full
        case noHostnameVerification
        case none
    }

    var backing: Backing

    /// Verify the certificate chain and that the certificate matches the
    /// hostname being connected to. This is the default and the only safe
    /// choice for production.
    public static let full = QUICCertificateVerification(backing: .full)

    /// Verify the certificate chain but not the hostname.
    public static let noHostnameVerification = QUICCertificateVerification(backing: .noHostnameVerification)

    /// Perform no certificate verification. Only for testing.
    public static let none = QUICCertificateVerification(backing: .none)
}

/// The TLS 1.3 key exchange group to offer.
public struct QUICKeyExchangeGroup: Hashable, Sendable {
    enum Backing: Hashable, Sendable {
        case secp256r1
        case secp384r1
        case x25519
        case x25519MLKEM768
    }

    var backing: Backing

    /// NIST P-256.
    public static let secp256r1 = QUICKeyExchangeGroup(backing: .secp256r1)
    /// NIST P-384.
    public static let secp384r1 = QUICKeyExchangeGroup(backing: .secp384r1)
    /// Curve25519. The default.
    public static let x25519 = QUICKeyExchangeGroup(backing: .x25519)
    /// Hybrid post-quantum key exchange combining X25519 with ML-KEM-768.
    public static let x25519MLKEM768 = QUICKeyExchangeGroup(backing: .x25519MLKEM768)
}
