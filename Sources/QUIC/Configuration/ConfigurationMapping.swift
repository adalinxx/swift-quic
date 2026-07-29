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
import NIOQUIC

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
extension QUICKeyExchangeGroup {
    var nioqGroup: NIOQUIC.KeyExchangeGroup {
        switch self.backing {
        case .secp256r1: return .secp256
        case .secp384r1: return .secp384
        case .x25519: return .x25519
        case .x25519MLKEM768: return .x25519MLKEM768
        }
    }
}

extension QUICCertificateVerification {
    var nioqVerification: NIOQUIC.CertificateVerification {
        switch self.backing {
        case .full: return .fullVerification
        case .noHostnameVerification: return .noHostnameVerification
        case .none: return .noVerification
        }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
extension QUICServer.Configuration {
    /// Maps to the underlying NIOQUIC configuration plus the TLS authenticator
    /// (which carries any in-memory certificates).
    func makeNIOQUICConfiguration() throws -> (NIOQUIC.QUICConfiguration, Authenticator?) {
        guard !self.applicationProtocols.isEmpty else {
            throw QUICConfigurationError("applicationProtocols must not be empty")
        }

        let authenticationConfiguration: AuthenticationConfiguration
        let authenticator: Authenticator?
        switch self.identity.backing {
        case .certificateFiles(let chainPath, let keyPath):
            authenticationConfiguration = .x509Certificates(
                certificateChainFilePath: chainPath,
                privateKeyFilePath: keyPath
            )
            authenticator = try Authenticator(
                certificateFilePath: chainPath,
                privateKeyFilePath: keyPath
            )
        case .certificates(let chain, let privateKey):
            // The file paths are never read: the injected Authenticator is the
            // sole source of certificates on the x509 path.
            authenticationConfiguration = .x509Certificates(
                certificateChainFilePath: "",
                privateKeyFilePath: ""
            )
            authenticator = try Authenticator(certificates: chain, privateKey: privateKey)
        case .rawPublicKeyFiles(let publicKeyPath, let privateKeyPath):
            authenticationConfiguration = .rawPublicKeys(
                publicKeyFilePath: publicKeyPath,
                privateKeyFilePath: privateKeyPath
            )
            authenticator = nil
        }

        let configuration = NIOQUIC.QUICConfiguration.server(
            serverName: self.serverName,
            authenticationConfiguration: authenticationConfiguration,
            keyExchangeGroup: self.keyExchangeGroup.nioqGroup,
            applicationProtocols: self.applicationProtocols,
            maxIdleTimeout: self.transport.maxIdleTimeout,
            initialMaxData: self.transport.initialMaxData,
            initialMaxStreamDataBidiLocal: self.transport.initialMaxStreamDataBidirectionalLocal,
            initialMaxStreamDataBidiRemote: self.transport.initialMaxStreamDataBidirectionalRemote,
            initialMaxStreamDataUni: self.transport.initialMaxStreamDataUnidirectional,
            initialMaxStreamsBidi: self.transport.maxBidirectionalStreams,
            initialMaxStreamsUni: self.transport.maxUnidirectionalStreams,
            keepAliveInterval: self.transport.keepAliveInterval,
            sendRetry: self.sendRetry,
            keyLogPath: self.keyLogFile,
            qLogConfiguration: self.qlog.map {
                .init(path: $0.directory, topic: $0.topic, description: $0.description)
            },
            maxDatagramFrameSize: self.transport.datagrams.isEnabled
                ? self.transport.datagrams.maxFrameSize : 0
        )
        return (configuration, authenticator)
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
extension QUICClient.Configuration {
    /// Maps to the underlying NIOQUIC configuration.
    func makeNIOQUICConfiguration() throws -> NIOQUIC.QUICConfiguration {
        guard !self.applicationProtocols.isEmpty else {
            throw QUICConfigurationError("applicationProtocols must not be empty")
        }

        let verificationConfiguration: VerificationConfiguration
        switch self.trustRoots.backing {
        case .system, .certificates:
            // The verifier object (built at connect time, once the event loop
            // is known) is the sole source of trust roots on the x509 path.
            verificationConfiguration = .x509Certificates(trustRootsFilePath: nil)
        case .pemFile(let path):
            verificationConfiguration = .x509Certificates(trustRootsFilePath: path)
        case .rawPublicKeyDERFile(let path):
            verificationConfiguration = .rawPublicKeys(publicKeyFilePath: path)
        }

        return NIOQUIC.QUICConfiguration.client(
            verificationConfiguration: verificationConfiguration,
            keyExchangeGroup: self.keyExchangeGroup.nioqGroup,
            applicationProtocols: self.applicationProtocols,
            maxIdleTimeout: self.transport.maxIdleTimeout,
            initialMaxData: self.transport.initialMaxData,
            initialMaxStreamDataBidiLocal: self.transport.initialMaxStreamDataBidirectionalLocal,
            initialMaxStreamDataBidiRemote: self.transport.initialMaxStreamDataBidirectionalRemote,
            initialMaxStreamDataUni: self.transport.initialMaxStreamDataUnidirectional,
            initialMaxStreamsBidi: self.transport.maxBidirectionalStreams,
            initialMaxStreamsUni: self.transport.maxUnidirectionalStreams,
            keepAliveInterval: self.transport.keepAliveInterval,
            forceVersionNegotiation: self.forceVersionNegotiation,
            keyLogPath: self.keyLogFile,
            qLogConfiguration: self.qlog.map {
                .init(path: $0.directory, topic: $0.topic, description: $0.description)
            },
            peerCertificateVerification: self.certificateVerification.nioqVerification,
            maxDatagramFrameSize: self.transport.datagrams.isEnabled
                ? self.transport.datagrams.maxFrameSize : 0
        )
    }

    /// Builds the certificate verifier for x509 trust configurations.
    /// Returns `nil` for raw-public-key trust (handled inside NIOQUIC).
    func makeAsyncVerifier(eventLoop: any EventLoop) throws -> AsyncVerifier? {
        let verification = self.certificateVerification.nioqVerification
        switch self.trustRoots.backing {
        case .system:
            return AsyncVerifier(certificateVerification: verification, eventLoop: eventLoop)
        case .pemFile(let path):
            return try AsyncVerifier(
                trustRootsPath: path,
                certificateVerification: verification,
                eventLoop: eventLoop
            )
        case .certificates(let certificates):
            return try AsyncVerifier(
                trustRoots: certificates,
                certificateVerification: verification,
                eventLoop: eventLoop
            )
        case .rawPublicKeyDERFile:
            return nil
        }
    }
}

/// A qlog (QUIC event logging) output configuration.
///
/// > Note: qlog output additionally requires the underlying QUIC
/// > implementation to be built with its `QlogOutput` trait enabled.
public struct QUICQLogConfiguration: Hashable, Sendable {
    /// The directory qlog files are written to.
    public var directory: String
    /// The qlog title.
    public var topic: String
    /// The qlog description.
    public var description: String

    /// Creates a qlog configuration.
    public init(directory: String, topic: String = "swift-quic", description: String = "swift-quic qlog") {
        self.directory = directory
        self.topic = topic
        self.description = description
    }
}
