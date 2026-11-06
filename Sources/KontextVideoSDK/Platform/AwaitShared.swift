import Foundation

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
            waiter.leave = Fanout.join(task) { waiter.resume(with: $0) }
        }
    } onCancel: {
        Task { @MainActor in waiter.resume(with: .failure(CancellationError())) }
    }
}

/// `awaitShared`, for at most `timeout` seconds: `nil` once they passed, the task going on for whoever
/// waits next. For work that can take longer than its caller can afford to wait (the user agent lookup).
@MainActor
func awaitShared<T: Sendable, Failure: Error>(_ task: Task<T, Failure>, timeout: TimeInterval) async throws -> T? {
    let waiter = Waiter<T?>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiter.continuation = continuation
            // Whichever comes first resumes the caller; the other finds it resumed and does nothing.
            let deadline = Task { @MainActor in
                try? await Task.sleep(seconds: timeout)
                waiter.resume(with: .success(nil))
            }
            waiter.leave = Fanout.join(task) { result in
                waiter.resume(with: result.map { Optional($0) })
                deadline.cancel()
            }
        }
    } onCancel: {
        Task { @MainActor in waiter.resume(with: .failure(CancellationError())) }
    }
}

/// One caller's continuation, resumed once: by the work's result, its timeout or the caller's cancellation,
/// whichever comes first. Resumed, it leaves its task's `Fanout`, so a caller that gave up holds nothing.
@MainActor
private final class Waiter<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?
    /// Removes this waiter from the task's fan-out; set once it joined.
    var leave: (() -> Void)?

    func resume(with result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        leave?()
        leave = nil
    }
}

/// The waiters of one shared task, and the one watcher that awaits it for all of them: a waiter per caller
/// spawning its own watcher left one task and one waiter behind per request for as long as the shared task ran,
/// which for a lookup that never returns (a WebKit hang) is the life of the process. A waiter that gave up leaves.
@MainActor
final class Fanout<T: Sendable> {
    /// The fan-out of each running task, by the task.
    private static var running: [AnyHashable: Fanout<T>] {
        get { fanoutsByType[ObjectIdentifier(T.self)] as? [AnyHashable: Fanout<T>] ?? [:] }
        set { fanoutsByType[ObjectIdentifier(T.self)] = newValue }
    }
    private var deliveries: [Int: (Result<T, Error>) -> Void] = [:]
    private var nextId = 0

    /// Adds `deliver` to `task`'s waiters, starting its watcher if it has none; returns how to leave.
    static func join<Failure: Error>(_ task: Task<T, Failure>, deliver: @escaping (Result<T, Error>) -> Void) -> () -> Void {
        let key = AnyHashable(task)
        let fanout: Fanout<T>
        if let existing = running[key] {
            fanout = existing
        } else {
            fanout = Fanout<T>()
            running[key] = fanout
            Task { @MainActor in
                let result = await task.result.mapError { $0 as Error }
                running[key] = nil
                for deliver in fanout.deliveries.values { deliver(result) }
                fanout.deliveries = [:]
            }
        }
        let id = fanout.nextId
        fanout.nextId += 1
        fanout.deliveries[id] = deliver
        return { [weak fanout] in fanout?.deliveries[id] = nil }
    }

    /// How many callers wait on `task` now. Tests only, which the analyzer does not see.
    static func waiting<Failure: Error>(on task: Task<T, Failure>) -> Int { // swiftlint:disable:this unused_declaration
        running[AnyHashable(task)]?.deliveries.count ?? 0
    }
}

/// Every type's fan-outs, by the type: a static stored property cannot be generic.
@MainActor
private var fanoutsByType: [ObjectIdentifier: Any] = [:]
