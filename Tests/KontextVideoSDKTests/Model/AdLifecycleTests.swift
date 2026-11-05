@testable import KontextVideoSDK
import Testing

/// `AdLifecycle` as two tables: every step from every phase to every phase, legal or not, and the flags each
/// phase reads as (the table in `VideoAd`'s documentation).
@Suite
struct AdLifecycleTests {
    typealias Phase = AdLifecycle.Phase

    private static let phases: [Phase] = [.offered, .invalidated(.expired), .reserved, .onScreen, .ending(.dismissed), .ended(.dismissed)]

    /// The legal steps; every other pair is refused and changes nothing.
    private static let legal: [(Phase, Phase)] = [
        (.offered, .invalidated(.expired)), (.offered, .reserved),
        (.reserved, .onScreen), (.reserved, .ending(.dismissed)),
        (.onScreen, .ending(.dismissed)),
        (.ending(.dismissed), .ended(.dismissed)),
    ]

    /// A lifecycle brought to `phase` through legal steps only, by the way an ad gets there on screen.
    private func lifecycle(at phase: Phase) -> AdLifecycle {
        let path: [Phase] = switch phase {
        case .offered: []
        case .invalidated: [phase]
        case .reserved: [.reserved]
        case .onScreen: [.reserved, .onScreen]
        case .ending: [.reserved, .onScreen, phase]
        case .ended(let reason): [.reserved, .onScreen, .ending(reason), phase]
        }
        var lifecycle = AdLifecycle()
        for step in path {
            let moved = lifecycle.transition(to: step)
            #expect(moved, "path to \(phase): \(step)")
        }
        return lifecycle
    }

    @Test func everyStepFromEveryPhase() {
        for from in Self.phases {
            for to in Self.phases {
                var lifecycle = lifecycle(at: from)
                let isLegal = Self.legal.contains { $0.0 == from && $0.1 == to }
                let moved = lifecycle.transition(to: to)
                #expect(moved == isLegal, "\(from) → \(to)")
                #expect(lifecycle.phase == (isLegal ? to : from), "\(from) → \(to): an illegal step changes nothing")
            }
        }
    }

    @Test func aSecondEndIsRefusedWhateverItsReason() {
        var lifecycle = lifecycle(at: .ending(.dismissed))
        let moved = lifecycle.transition(to: .ending(.destroyed))
        #expect(!moved)
        #expect(lifecycle.phase == .ending(.dismissed))
    }

    @Test func theFlagsOfEveryPhase() {
        // phase, wasShown, hasEnded, invalidationReason, isPresented
        let rows: [(Phase, Bool, Bool, VideoAd.InvalidationReason?, Bool)] = [
            (.offered, false, false, nil, false),
            (.invalidated(.expired), false, false, .expired, false),
            (.reserved, true, false, nil, false),
            (.onScreen, true, false, nil, true),
            (.ending(.dismissed), true, true, nil, true),
            (.ended(.dismissed), true, true, nil, true),
        ]
        for (phase, wasShown, hasEnded, invalidation, isPresented) in rows {
            let lifecycle = lifecycle(at: phase)
            #expect(lifecycle.wasShown == wasShown, "\(phase) wasShown")
            #expect(lifecycle.hasEnded == hasEnded, "\(phase) hasEnded")
            #expect(lifecycle.invalidationReason == invalidation, "\(phase) invalidationReason")
            #expect(lifecycle.isPresented == isPresented, "\(phase) isPresented")
        }
    }

    @Test func anAdEndedBeforeItWasPresentedWasNeverPresented() {
        var lifecycle = lifecycle(at: .reserved)
        lifecycle.transition(to: .ending(.destroyed))
        #expect(lifecycle.hasEnded && !lifecycle.isPresented, "a linear ad UIKit never presented")
    }

    @Test func invalidationIsFinal() {
        var lifecycle = lifecycle(at: .invalidated(.rejected))
        let reserved = lifecycle.transition(to: .reserved)
        let invalidatedAgain = lifecycle.transition(to: .invalidated(.expired))
        #expect(!reserved && !invalidatedAgain)
        #expect(lifecycle.invalidationReason == .rejected)
    }
}
