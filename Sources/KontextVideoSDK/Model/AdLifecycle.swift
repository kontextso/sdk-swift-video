/// Where an ad is in its life, as a plain value: the phases, the one table of legal steps between them, and
/// the flags the public API reads off them.
///
/// Why: the lifecycle guarantee (nothing to the delegate before `show`; after a successful `show` exactly one
/// `didEnd`) rests on these steps moving one way only. Kept apart from `VideoAd`, with no UIKit and no
/// effects, the table can be read in one place and tested cell by cell.
///
/// How: `VideoAd` holds one `AdLifecycle` and moves it only through `transition(to:)`, which says whether the
/// step was legal; an illegal one (a late event, a second end) changes nothing, and the caller stops there.
/// Every public flag of the ad reads the lifecycle live, never a copy.
///
/// ```
///   offered ──► invalidated(reason)                 ended before show: nothing delivered
///      │
///      └──► reserved ──► onScreen ──► ending(reason) ──► ended(reason)
///               │                         ▲
///               └─────────────────────────┘           show accepted, never presented (a linear ad UIKit refused)
/// ```
///
/// | Phase | `wasShown` | `hasEnded` | `invalidationReason` | `isPresented` |
/// |---|---|---|---|---|
/// | offered | `false` | `false` | `nil` | `false` |
/// | invalidated | `false` | `false` | set | `false` |
/// | reserved | `true` | `false` | `nil` | `false` |
/// | onScreen | `true` | `false` | `nil` | `true` |
/// | ending, ended | `true` | `true` | `nil` | as it was |
struct AdLifecycle: Equatable {
    /// The phases, each reached only through `transition(to:)`.
    enum Phase: Equatable {
        /// Returned by `format(_:)`; `isLoaded` says whether the creative is ready.
        case offered
        /// Ended before `show`: nothing was delivered.
        case invalidated(VideoAd.InvalidationReason)
        /// `show` committed and took the app's one slot; a linear ad waits for UIKit to present it.
        case reserved
        /// The creative is presented: the page was told to show, the meter and the clock run.
        case onScreen
        /// The ad is ending; a linear ad is being dismissed, and `didEnd` follows once that finished.
        case ending(VideoAd.EndReason)
        /// `didEnd` was delivered.
        case ended(VideoAd.EndReason)
    }

    private(set) var phase = Phase.offered
    /// The creative reached the screen (the phase was `onScreen`). Stays `true` after the end: an ad that was on
    /// screen without an impression closes.
    private(set) var isPresented = false

    /// Moves to `next` when that is a legal step, and says whether it did: offered → invalidated or reserved,
    /// reserved → on screen or ending, on screen → ending, ending → ended. Anything else (a late event, a
    /// second end) changes nothing.
    @discardableResult
    mutating func transition(to next: Phase) -> Bool {
        switch (phase, next) {
        case (.offered, .invalidated), (.offered, .reserved), (.reserved, .onScreen), (.reserved, .ending),
             (.onScreen, .ending), (.ending, .ended):
            phase = next
            if next == .onScreen { isPresented = true }
            return true
        default:
            return false
        }
    }

    /// `true` from a successful `show` on.
    var wasShown: Bool {
        switch phase {
        case .offered, .invalidated: false
        case .reserved, .onScreen, .ending, .ended: true
        }
    }

    /// `true` once the ad began to end.
    var hasEnded: Bool {
        switch phase {
        case .ending, .ended: true
        case .offered, .invalidated, .reserved, .onScreen: false
        }
    }

    /// Why the ad ended before it was shown, once it did.
    var invalidationReason: VideoAd.InvalidationReason? {
        if case .invalidated(let reason) = phase { return reason }
        return nil
    }
}
