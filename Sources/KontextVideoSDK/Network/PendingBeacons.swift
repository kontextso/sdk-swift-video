import Foundation

/// The outcome beacons of one `VideoAds` still in flight, `notUsed` (a `reject()`, a `destroy()`) and `error`, which
/// its next ads request waits for (`settled(within:)`), for at most `maxWait`.
///
/// Why: the server re-serves a session's unshown bid until it hears that bid's outcome. A `reject()` followed at once
/// by `format()` would race its own `notUsed` beacon, and the answer could bring the rejected bid back, which the
/// SDK ignores as spent (a no-fill, `alreadyUsed`) instead of getting the next one. The cap keeps a slow or dead
/// beacon route from holding ads back.
///
/// ```
/// reject()  ── notUsed beacon ──────────── answered ──┐
/// format()  ── /config ── the body ── waits ──────────┴── POST /video/ads
///                                     (at most 2 s)
/// ```
///
/// `Tracker` counts each such beacon in (`begin()`), `BeaconClient` reports it done whatever it ended with (an
/// answer, a failure, a timeout), and `AdsFetcher` waits before the POST.
@MainActor
final class PendingBeacons {
    /// The longest an ads request waits, in seconds.
    static var maxWait: TimeInterval = 2
    /// The beacons whose outcome the server needs before the next request.
    static let awaited: Set<String> = ["notUsed", "error"]

    /// The beacons in flight.
    private(set) var inFlight = 0
    /// Each request waiting, and the timer that ends its wait.
    private var waiters: [UUID: (continuation: CheckedContinuation<Void, Never>, deadline: Task<Void, Never>)] = [:]

    /// One beacon leaves; the closure returned says it ended, from any thread, once.
    func begin() -> @Sendable () -> Void {
        inFlight += 1
        return { Task { @MainActor in self.end() } }
    }

    private func end() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        for id in Array(waiters.keys) { resume(id) }
    }

    /// Returns once no beacon is in flight, after `timeout` seconds, or when the calling task is cancelled,
    /// whichever comes first; `true` when none is left in flight.
    @discardableResult
    func settled(within timeout: TimeInterval) async -> Bool {
        guard inFlight > 0 else { return true }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let deadline = Task { @MainActor in
                    try? await Task.sleep(seconds: timeout)
                    self.resume(id)
                }
                waiters[id] = (continuation, deadline)
            }
        } onCancel: {
            Task { @MainActor in self.resume(id) }
        }
        return inFlight == 0
    }

    private func resume(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.deadline.cancel()
        waiter.continuation.resume()
    }
}
