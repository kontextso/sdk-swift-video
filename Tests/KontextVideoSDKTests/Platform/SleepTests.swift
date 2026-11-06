@testable import KontextVideoSDK
import Testing

/// `Task.sleep(seconds:)`: a wait that `UInt64` cannot hold is clamped, never a trap.
@Suite
struct SleepTests {
    @Test func aNegativeOrNaNWaitIsNone() async throws {
        try await Task.sleep(seconds: -5)
        try await Task.sleep(seconds: .nan)
    }

    @Test func anEndlessWaitIsClampedAndStillCancellable() async {
        for seconds in [Double.infinity, 1e300, Double(UInt64.max)] {
            let sleeper = Task { try await Task.sleep(seconds: seconds) }
            sleeper.cancel()
            do {
                try await sleeper.value
                Issue.record("\(seconds): expected cancellation")
            } catch {
                #expect(error is CancellationError, "\(seconds)")
            }
        }
    }
}
