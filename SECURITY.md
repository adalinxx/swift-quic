# Security Policy

## Supported versions

The `main` branch. (Versioned releases are currently blocked on upstream
tagging; see [ROADMAP.md](ROADMAP.md).)

## Reporting a vulnerability

Please report suspected vulnerabilities privately via
[GitHub Security Advisories](https://github.com/adalinxx/swift-quic/security/advisories/new)
("Report a vulnerability"). Do not open a public issue.

You can expect an acknowledgement within 7 days. Fixes are coordinated
through a draft advisory before public disclosure.

## Scope notes

- Transport-protocol and TLS-handshake vulnerabilities generally belong to
  the underlying stack ([apple/swift-nio-quic](https://github.com/apple/swift-nio-quic)
  and swift-network-evolution); we will help triage and route them upstream.
- `QUICCertificateVerification.none` and `QUICIdentity.selfSigned` are
  explicitly for development and testing; reports about their intentional
  behavior are out of scope.
