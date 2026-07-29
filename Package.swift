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
        // Pinned to a revision: the datagram (RFC 9221) support and in-memory
        // trust-root APIs this library builds on are newer than the 0.1.0 tag.
        .package(url: "https://github.com/apple/swift-nio-quic", revision: "19fd6ac5de463717fb1d957381a91ff96f5623b5"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-network-evolution", .upToNextMinor(from: "0.1.1")),
        .package(url: "https://github.com/apple/swift-nio-quic-helpers.git", .upToNextMinor(from: "0.1.0")),
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
