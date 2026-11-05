@testable import KontextVideoSDK
import Testing

/// `AdState` as two tables: every step from every phase to every phase, legal or not, and the flags each
/// phase reads as (the table in `VideoAd`'s documentation); then the milestones, each recorded once.
@Suite
struct AdStateTests {
    typealias Phase = AdState.Phase

    private static let phases: [Phase] = [.offered, .invalidated(.expired), .reserved, .onScreen, .ending(.dismissed), .ended(.dismissed)]

    /// The legal steps; every other pair is refused and changes nothing.
    private static let legal: [(Phase, Phase)] = [
        (.offered, .invalidated(.expired)), (.offered, .reserved),
        (.reserved, .onScreen), (.reserved, .ending(.dismissed)),
        (.onScreen, .ending(.dismissed)),
        (.ending(.dismissed), .ended(.dismissed)),
    ]

    /// A state brought to `phase` through legal steps only, by the way an ad gets there on screen.
    private func reached(_ phase: Phase) -> AdState {
        let path: [Phase] = switch phase {
        case .offered: []
        case .invalidated: [phase]
        case .reserved: [.reserved]
        case .onScreen: [.reserved, .onScreen]
        case .ending: [.reserved, .onScreen, phase]
        case .ended(let reason): [.reserved, .onScreen, .ending(reason), phase]
        }
        var state = AdState()
        for step in path {
            let moved = state.transition(to: step)
            #expect(moved, "path to \(phase): \(step)")
        }
        return state
    }

    @Test func everyStepFromEveryPhase() {
        for from in Self.phases {
            for to in Self.phases {
                var state = reached(from)
                let isLegal = Self.legal.contains { $0.0 == from && $0.1 == to }
                let moved = state.transition(to: to)
                #expect(moved == isLegal, "\(from) → \(to)")
                #expect(state.phase == (isLegal ? to : from), "\(from) → \(to): an illegal step changes nothing")
            }
        }
    }

    @Test func aSecondEndIsRefusedWhateverItsReason() {
        var state = reached(.ending(.dismissed))
        let moved = state.transition(to: .ending(.destroyed))
        #expect(!moved)
        #expect(state.phase == .ending(.dismissed))
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
            let state = reached(phase)
            #expect(state.wasShown == wasShown, "\(phase) wasShown")
            #expect(state.hasEnded == hasEnded, "\(phase) hasEnded")
            #expect(state.invalidationReason == invalidation, "\(phase) invalidationReason")
            #expect(state.isPresented == isPresented, "\(phase) isPresented")
        }
    }

    @Test func anAdEndedBeforeItWasPresentedWasNeverPresented() {
        var state = reached(.reserved)
        state.transition(to: .ending(.destroyed))
        #expect(state.hasEnded && !state.isPresented, "a linear ad UIKit never presented")
    }

    @Test func invalidationIsFinal() {
        var state = reached(.invalidated(.rejected))
        let reserved = state.transition(to: .reserved)
        let invalidatedAgain = state.transition(to: .invalidated(.expired))
        #expect(!reserved && !invalidatedAgain)
        #expect(state.invalidationReason == .rejected)
    }

    @Test func eachMilestoneIsSetOnceAndNeverUndone() {
        var state = AdState()
        #expect(!state.loaded && !state.completed && !state.impressionRecorded && state.failure == nil)
        state.markLoaded()
        state.markLoaded()
        #expect(state.loaded)
        let first = state.markImpression()
        let second = state.markImpression()
        #expect(first && !second, "the impression fires the first time only")
        #expect(state.impressionRecorded)
        state.markCompleted()
        state.markCompleted()
        #expect(state.completed)
        // Every later step keeps them.
        for step: Phase in [.reserved, .onScreen, .ending(.completed), .ended(.completed)] {
            state.transition(to: step)
            #expect(state.loaded && state.completed && state.impressionRecorded, "after \(step)")
        }
    }

    @Test func milestonesDoNotMoveThePhase() {
        var state = reached(.reserved)
        state.markLoaded()
        state.markCompleted()
        _ = state.markImpression()
        state.markFailed(.notLoaded)
        #expect(state.phase == .reserved)
    }

    @Test func theFailureIsReadBackAndTheFirstStays() {
        var state = reached(.onScreen)
        state.markFailed(.creativeFailed(code: 1))
        state.markFailed(.creativeFailed(code: 2))
        state.transition(to: .ending(.failed))
        state.transition(to: .ended(.failed))
        #expect(state.failure == .creativeFailed(code: 1))
    }
}
