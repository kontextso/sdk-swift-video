@testable import KontextVideoSDK
import Testing

/// `AdLifecycle`'s table, pure: every move from every phase to every phase, legal or not.
@Suite
struct AdLifecycleTests {
    typealias Phase = AdLifecycle.Phase

    static let phases: [Phase] = [.offered, .invalidated(.expired), .reserved, .onScreen, .ending(.dismissed), .ended(.dismissed)]

    /// The legal moves; every other pair is refused.
    static let legal: [(Phase, Phase)] = [
        (.offered, .invalidated(.expired)), (.offered, .reserved),
        (.reserved, .onScreen), (.reserved, .ending(.dismissed)),
        (.onScreen, .ending(.dismissed)),
        (.ending(.dismissed), .ended(.dismissed)),
    ]

    @Test func everyMoveFromEveryPhase() {
        for from in Self.phases {
            for to in Self.phases {
                let isLegal = Self.legal.contains { $0.0 == from && $0.1 == to }
                #expect(AdLifecycle.canMove(from: from, to: to) == isLegal, "\(from) → \(to)")
            }
        }
    }

    @Test func theReasonDoesNotChangeTheRule() {
        #expect(AdLifecycle.canMove(from: .onScreen, to: .ending(.failed)))
        #expect(AdLifecycle.canMove(from: .ending(.closed), to: .ended(.destroyed)))
        #expect(!AdLifecycle.canMove(from: .ending(.dismissed), to: .ending(.destroyed)), "a second end")
        #expect(!AdLifecycle.canMove(from: .invalidated(.rejected), to: .invalidated(.expired)), "invalidation is final")
    }
}
