@testable import KontextVideoSDK
import Testing

/// `AdState`, the data: its moves (every pair, through `moveTo`, changes the phase only when `AdLifecycle`
/// allows it), the flags each phase reads as (the table in its documentation), and the milestones, each
/// recorded once.
@Suite
struct AdStateTests {
    typealias Phase = AdLifecycle.Phase

    /// A state brought to `phase` through legal steps only, the way an ad gets there on screen.
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
            let moved = state.moveTo(step)
            #expect(moved, "path to \(phase): \(step)")
        }
        return state
    }

    @Test func everyMoveFromEveryPhase() {
        for from in AdLifecycleTests.phases {
            for to in AdLifecycleTests.phases {
                var state = reached(from)
                let isLegal = AdLifecycleTests.legal.contains { $0.0 == from && $0.1 == to }
                let moved = state.moveTo(to)
                #expect(moved == isLegal, "\(from) → \(to)")
                #expect(state.phase == (isLegal ? to : from), "\(from) → \(to): an illegal move changes nothing")
            }
        }
    }

    @Test func aSecondEndIsRefusedWhateverItsReason() {
        var state = reached(.ending(.dismissed))
        let moved = state.moveTo(.ending(.destroyed))
        #expect(!moved)
        #expect(state.phase == .ending(.dismissed))
    }

    @Test func theFlagsOfEveryPhase() {
        // phase, wasShown, hasEnded, invalidationReason, wasOnScreen
        let rows: [(Phase, Bool, Bool, VideoAd.InvalidationReason?, Bool)] = [
            (.offered, false, false, nil, false),
            (.invalidated(.expired), false, false, .expired, false),
            (.reserved, true, false, nil, false),
            (.onScreen, true, false, nil, true),
            (.ending(.dismissed), true, true, nil, true),
            (.ended(.dismissed), true, true, nil, true),
        ]
        for (phase, wasShown, hasEnded, invalidation, wasOnScreen) in rows {
            let state = reached(phase)
            #expect(state.wasShown == wasShown, "\(phase) wasShown")
            #expect(state.hasEnded == hasEnded, "\(phase) hasEnded")
            #expect(state.invalidationReason == invalidation, "\(phase) invalidationReason")
            #expect(state.wasOnScreen == wasOnScreen, "\(phase) wasOnScreen")
        }
    }

    @Test func anAdEndedBeforeItReachedTheScreenWasNeverOnScreen() {
        var state = reached(.reserved)
        state.moveTo(.ending(.destroyed))
        #expect(state.hasEnded && !state.wasOnScreen, "a linear ad UIKit never presented")
    }

    @Test func invalidationIsFinal() {
        var state = reached(.invalidated(.rejected))
        let reserved = state.moveTo(.reserved)
        let invalidatedAgain = state.moveTo(.invalidated(.expired))
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
            state.moveTo(step)
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
        state.moveTo(.ending(.failed))
        state.moveTo(.ended(.failed))
        #expect(state.failure == .creativeFailed(code: 1))
    }
}
