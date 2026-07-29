//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-quic open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// The core currency types users need to work with this library. Re-exported so
// that `import QUIC` is sufficient for the common path.
@_exported import struct NIOCore.ByteBuffer
@_exported import enum NIOCore.SocketAddress
