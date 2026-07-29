//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Testing
import X509

import struct Foundation.Date

import NIOQUIC

@testable import QUIC

@Suite
struct ServerConfigurationMappingTests {
    private func makeIdentity() throws -> QUICSelfSignedIdentity {
        try QUICIdentity.selfSigned()
    }

    @Test
    func emptyALPNThrows() throws {
        let configuration = QUICServer.Configuration(
            identity: try self.makeIdentity().identity,
            applicationProtocols: []
        )
        #expect(throws: QUICConfigurationError.self) {
            _ = try configuration.makeNIOQUICConfiguration()
        }
    }

    @Test
    func inMemoryIdentityProducesAuthenticator() throws {
        let configuration = QUICServer.Configuration(
            identity: try self.makeIdentity().identity,
            applicationProtocols: ["proto-a", "proto-b"]
        )
        let (nioq, authenticator) = try configuration.makeNIOQUICConfiguration()
        #expect(authenticator != nil)
        #expect(nioq.role == .server)
        #expect(nioq.applicationProtocols == ["proto-a", "proto-b"])
    }

    @Test
    func transportParametersAreMapped() throws {
        var configuration = QUICServer.Configuration(
            identity: try self.makeIdentity().identity,
            applicationProtocols: ["p"]
        )
        configuration.transport.maxIdleTimeout = .seconds(7)
        configuration.transport.initialMaxData = 1234
        configuration.transport.initialMaxStreamDataBidirectionalLocal = 111
        configuration.transport.initialMaxStreamDataBidirectionalRemote = 222
        configuration.transport.initialMaxStreamDataUnidirectional = 333
        configuration.transport.maxBidirectionalStreams = 17
        configuration.transport.maxUnidirectionalStreams = 19
        configuration.transport.keepAliveInterval = .seconds(3)

        let (nioq, _) = try configuration.makeNIOQUICConfiguration()
        #expect(nioq.maxIdleTimeout == .seconds(7))
        #expect(nioq.initialMaxData == 1234)
        #expect(nioq.initialMaxStreamDataBidiLocal == 111)
        #expect(nioq.initialMaxStreamDataBidiRemote == 222)
        #expect(nioq.initialMaxStreamDataUni == 333)
        #expect(nioq.initialMaxStreamsBidi == 17)
        #expect(nioq.initialMaxStreamsUni == 19)
    }

    @Test
    func disablingDatagramsAdvertisesZero() throws {
        var configuration = QUICServer.Configuration(
            identity: try self.makeIdentity().identity,
            applicationProtocols: ["p"]
        )
        configuration.transport.datagrams.isEnabled = false
        let (nioq, _) = try configuration.makeNIOQUICConfiguration()
        #expect(nioq.maxDatagramFrameSize == 0)

        configuration.transport.datagrams.isEnabled = true
        configuration.transport.datagrams.maxFrameSize = 1200
        let (enabled, _) = try configuration.makeNIOQUICConfiguration()
        #expect(enabled.maxDatagramFrameSize == 1200)
    }

    @Test
    func keyExchangeGroupsAreMapped() throws {
        #expect(QUICKeyExchangeGroup.x25519.nioqGroup == .x25519)
        #expect(QUICKeyExchangeGroup.secp256r1.nioqGroup == .secp256)
        #expect(QUICKeyExchangeGroup.secp384r1.nioqGroup == .secp384)
        #expect(QUICKeyExchangeGroup.x25519MLKEM768.nioqGroup == .x25519MLKEM768)
    }
}

@Suite
struct ClientConfigurationMappingTests {
    @Test
    func emptyALPNThrows() {
        let configuration = QUICClient.Configuration(applicationProtocols: [])
        #expect(throws: QUICConfigurationError.self) {
            _ = try configuration.makeNIOQUICConfiguration()
        }
    }

    @Test
    func defaultsToSystemTrustAndFullVerification() throws {
        let configuration = QUICClient.Configuration(applicationProtocols: ["p"])
        let nioq = try configuration.makeNIOQUICConfiguration()
        #expect(nioq.role == .client)
        #expect(nioq.peerCertificateVerification == .fullVerification)
        if case .x509Certificates(let path) = nioq.verificationConfiguration {
            #expect(path == nil)
        } else {
            Issue.record("expected x509 verification configuration")
        }
    }

    @Test
    func verificationModesAreMapped() {
        #expect(QUICCertificateVerification.full.nioqVerification == .fullVerification)
        #expect(QUICCertificateVerification.noHostnameVerification.nioqVerification == .noHostnameVerification)
        #expect(QUICCertificateVerification.none.nioqVerification == .noVerification)
    }

    @Test
    func rawPublicKeyTrustMapsToRawPublicKeyVerification() throws {
        var configuration = QUICClient.Configuration(applicationProtocols: ["p"])
        configuration.trustRoots = .rawPublicKey(derFile: "/tmp/key.der")
        let nioq = try configuration.makeNIOQUICConfiguration()
        if case .rawPublicKeys(let path) = nioq.verificationConfiguration {
            #expect(path == "/tmp/key.der")
        } else {
            Issue.record("expected raw public key verification configuration")
        }
    }
}

@Suite
struct SelfSignedIdentityTests {
    @Test
    func generatesCertificateWithSubjectAlternativeNames() throws {
        let identity = try QUICIdentity.selfSigned(
            commonName: "unit-test",
            dnsNames: ["example.test"],
            ipAddresses: ["127.0.0.1", "::1"]
        )
        let certificate = identity.certificate
        #expect(certificate.subject.description.contains("unit-test"))
        let sans = try #require(try certificate.extensions.subjectAlternativeNames)
        var dnsNames: [String] = []
        var ipCount = 0
        for san in sans {
            switch san {
            case .dnsName(let name): dnsNames.append(name)
            case .ipAddress: ipCount += 1
            default: ()
            }
        }
        #expect(dnsNames == ["example.test"])
        #expect(ipCount == 2)
    }

    @Test
    func certificateIsCurrentlyValid() throws {
        let identity = try QUICIdentity.selfSigned(validFor: .seconds(3600))
        let now = Date()
        #expect(identity.certificate.notValidBefore <= now)
        #expect(identity.certificate.notValidAfter >= now.addingTimeInterval(3000))
    }

    @Test
    func rejectsInvalidIPAddress() {
        #expect(throws: QUICConfigurationError.self) {
            _ = try QUICIdentity.selfSigned(ipAddresses: ["not-an-ip"])
        }
    }

    @Test
    func parsesRawIPBytes() {
        #expect(QUICSelfSignedIdentity.rawIPAddressBytes("127.0.0.1") == [127, 0, 0, 1])
        #expect(QUICSelfSignedIdentity.rawIPAddressBytes("::1")?.count == 16)
        #expect(QUICSelfSignedIdentity.rawIPAddressBytes("999.1.1.1") == nil)
    }
}
