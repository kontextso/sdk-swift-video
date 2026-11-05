@testable import KontextVideoSDK
import Testing

/// `SdkLifecycle`'s table, pure: every move from every phase to every phase, legal or refused.
@Suite
struct SdkLifecycleTests {
    typealias State = KontextVideo.State

    static let states: [State] = [.notInitialized, .initializing, .enabled, .disabled(reason: "publisherDisabled"), .failed]

    /// The legal moves; every other pair is refused.
    static let legal: [(State, State)] = [
        (.notInitialized, .initializing),
        (.initializing, .enabled), (.initializing, .disabled(reason: "publisherDisabled")), (.initializing, .failed),
        (.enabled, .disabled(reason: "publisherDisabled")),
        (.failed, .initializing),
    ]

    @Test func everyMoveFromEveryState() {
        for from in Self.states {
            for to in Self.states {
                let isLegal = Self.legal.contains { $0.0 == from && $0.1 == to }
                #expect(SdkLifecycle.canMove(from: from, to: to) == isLegal, "\(from) → \(to)")
            }
        }
    }

    @Test func disabledMovesOnlyToAnotherReason() {
        #expect(SdkLifecycle.canMove(from: .disabled(reason: "publisherDisabled"), to: .disabled(reason: "killed")))
        #expect(!SdkLifecycle.canMove(from: .disabled(reason: "killed"), to: .disabled(reason: "killed")))
    }
}
