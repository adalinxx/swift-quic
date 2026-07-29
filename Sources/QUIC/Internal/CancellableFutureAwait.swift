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
import Synchronization

/// Awaits an `EventLoopFuture`, honoring task cancellation.
///
/// `EventLoopFuture.get()` cannot be interrupted; if the future never
/// completes, the awaiting task is stuck forever — even if it is cancelled.
/// This helper ends the *await* with `CancellationError` when the task is
/// cancelled, while the underlying operation keeps running to completion on
/// its event loop.
func withCancellableWait(_ future: EventLoopFuture<Void>) async throws {
    let box = WaiterBox()
    future.whenComplete { result in
        box.resume(with: result)
    }
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.install(continuation)
        }
    } onCancel: {
        box.resume(with: .failure(CancellationError()))
    }
}

/// Single-resume rendezvous between a future callback, a cancellation handler,
/// and the awaiting continuation, in any arrival order.
private final class WaiterBox: Sendable {
    private enum State {
        case idle
        case finishedEarly(Result<Void, any Error>)
        case installed(CheckedContinuation<Void, any Error>)
        case done
    }

    private let state = Mutex<State>(.idle)

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let pendingResult: Result<Void, any Error>? = self.state.withLock { state in
            switch state {
            case .idle:
                state = .installed(continuation)
                return nil
            case .finishedEarly(let result):
                state = .done
                return result
            case .installed, .done:
                fatalError("continuation installed twice")
            }
        }
        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    func resume(with result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = self.state.withLock { state in
            switch state {
            case .idle:
                state = .finishedEarly(result)
                return nil
            case .installed(let continuation):
                state = .done
                return continuation
            case .finishedEarly, .done:
                // Already resolved (e.g. completion racing cancellation);
                // first resolution wins.
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}
