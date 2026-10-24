import Foundation

/// Awaits work that belongs to a `VideoAds` (a request, a load), not to the caller. Cancelling the
/// caller's task makes only this call throw `CancellationError`, at once; the work keeps running, and
/// other callers waiting for it, or the next call, get its result.
@MainActor
func awaitShared<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
    let waiter = Waiter<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiter.continuation = continuation
            Task { @MainActor in waiter.resume(with: await task.result) }
        }
    } onCancel: {
        Task { @MainActor in waiter.resume(with: .failure(CancellationError())) }
    }
}

/// One caller's continuation, resumed once: by the work's result or by the caller's cancellation,
/// whichever comes first.
@MainActor
private final class Waiter<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?

    func resume(with result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
