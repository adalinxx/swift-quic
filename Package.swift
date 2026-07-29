// swift-tools-version:6.3
//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "swift-quic",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "QUIC", targets: ["QUIC"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", from: "2.92.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.12.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0-beta.2"),
        // Pinned to the adalinxx fork: upstream main (19fd6ac) plus three fixes
        // we have prepared as upstream PRs (typed reset errors, datagram write
        // promise completion, no-trap teardown). See docs/upstream-issues/.
        .package(url: "https://github.com/adalinxx/swift-nio-quic", revision: "c1246a13a84ebadb0b1e76c3e177a9aa35713bd2"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.0"),
        // Same identity/URL as the swift-nio-quic fork's dependency:
        // 0.1.1 plus the teardown-crash fix.
        .package(url: "https://github.com/adalinxx/swift-network-evolution", revision: "d6f9fe73e95ba59d7f1fe354f6d61c99e54f3484"),
        .package(url: "https://github.com/apple/swift-nio-quic-helpers.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "QUIC",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "NIOQUIC", package: "swift-nio-quic"),
                .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
                .product(name: "SwiftNetwork", package: "swift-network-evolution"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "quic-echo",
            dependencies: [
                .target(name: "QUIC"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "quic-bench",
            dependencies: [
                .target(name: "QUIC"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "quic-interop",
            dependencies: [
                .target(name: "QUIC"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "QUICTests",
            dependencies: [
                .target(name: "QUIC")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "QUICIntegrationTests",
            dependencies: [
                .target(name: "QUIC"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
