/// `Task.sleep` in seconds, the SDK's one conversion to nanoseconds.
///
/// Why: `UInt64(seconds * 1_000_000_000)` traps for a negative, NaN or infinite value or one over about 584
/// years, and the SDK's waits come from knobs, server values and arithmetic on them. Here a negative or NaN wait
/// is none and anything past `longestSleep` is that long. Every timer in the SDK sleeps through it.
extension Task where Success == Never, Failure == Never {
    /// The longest a sleep lasts: ten years, far past any wait the SDK has and far below `UInt64`'s limit.
    static var longestSleep: Double { 10 * 365 * 24 * 3600 }

    /// Suspends for `seconds`, clamped to `0...longestSleep` (NaN as 0). Throws `CancellationError` when cancelled.
    static func sleep(seconds: Double) async throws {
        let clamped = seconds.isNaN ? 0 : min(max(0, seconds), longestSleep)
        try await sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}
