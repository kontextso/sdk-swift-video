@testable import KontextVideoSDK
import Testing

/// How a page's close ends an ad, as a table: the reason the page gives, the format and whether the video
/// completed, against the beacon and the end reason.
@Suite
@MainActor
struct CloseOutcomeTests {
    @Test func everyCloseReasonByFormatAndCompletion() {
        // reason, linear, completed, beacon, end reason
        let rows: [(FrameEvent.CloseReason, Bool, Bool, String?, VideoAd.EndReason)] = [
            (.close, true, false, "skip", .skipped),
            (.resume, true, false, "skip", .skipped),
            (.complete, true, false, "skip", .skipped),
            (.close, true, true, "close", .closed),
            (.resume, true, true, "close", .resumed),
            (.complete, true, true, nil, .completed),
            (.close, false, false, "close", .closed),
            (.resume, false, false, "close", .resumed),
            (.complete, false, false, nil, .completed),
            (.close, false, true, "close", .closed),
        ]
        for (reason, isLinear, isCompleted, beacon, endReason) in rows {
            let outcome = reason.outcome(isLinear: isLinear, isCompleted: isCompleted)
            #expect(outcome.beacon == beacon && outcome.endReason == endReason, "\(reason), linear \(isLinear), completed \(isCompleted)")
        }
    }
}
