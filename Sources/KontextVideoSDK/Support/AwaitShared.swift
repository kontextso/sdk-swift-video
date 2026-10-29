/// Waits for someone else's work without owning it: any number of callers can wait on the same running
/// task (a request, a creative load), each gets the task's result when it finishes, and a caller that is
/// cancelled stops waiting immediately (`CancellationError`) without cancelling the task or affecting the
/// other callers. Starting, storing and cancelling the work is the owner's job (`VideoAds.request`,
/// `VideoAd.loading`); this is only the joining half. A plain `task.value` would keep a cancelled caller
/// waiting until the task finished. Works for a task that cannot fail too (`/config`'s): only the
/// caller's cancellation throws then.
@MainActor
func awaitShared<T: Sendable, Failure: Error>(_ task: Task<T, Failure>) async throws -> T {
    let waiter = Waiter<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiter.continuation = continuation
            Task { @MainActor in waiter.resume(with: await task.result.mapError { $0 as Error }) }
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
