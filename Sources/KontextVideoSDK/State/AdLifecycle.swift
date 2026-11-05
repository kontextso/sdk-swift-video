/// The rules of an ad's life, stateless: its phases and the one table of legal moves between them. It holds
/// nothing; the data, the one source of truth, is `AdState`, which asks `canMove(from:to:)` before every move.
///
/// Why: the lifecycle guarantee (nothing to the delegate before `show`; after a successful `show` exactly one
/// `didEnd`) rests on these moves going one way only. Kept apart from the data, with no UIKit and no effects,
/// the table can be read in one place and tested cell by cell.
///
/// ```
///   offered ──► invalidated(reason)                 ended before show: nothing delivered
///      │
///      └──► reserved ──► onScreen ──► ending(reason) ──► ended(reason)
///               │                         ▲
///               └─────────────────────────┘           show accepted, never on screen (a linear ad UIKit refused)
/// ```
enum AdLifecycle {
    /// The phases, each reached only through `AdState.moveTo(_:)`.
    enum Phase: Equatable {
        /// Returned by `format(_:)`; `isLoaded` says whether the creative is ready.
        case offered
        /// Ended before `show`: nothing was delivered.
        case invalidated(VideoAd.InvalidationReason)
        /// `show` committed and took the app's one slot; a linear ad waits for UIKit to present it.
        case reserved
        /// The creative is on screen: the page was told to show, the meter and the clock run.
        case onScreen
        /// The ad is ending; a linear ad is being dismissed, and `didEnd` follows once that finished.
        case ending(VideoAd.EndReason)
        /// `didEnd` was delivered.
        case ended(VideoAd.EndReason)
    }

    /// Whether `from` may move to `to`: offered → invalidated or reserved, reserved → on screen or ending,
    /// on screen → ending, ending → ended. Anything else (a late event, a second end) is refused.
    static func canMove(from: Phase, to: Phase) -> Bool {
        switch (from, to) {
        case (.offered, .invalidated), (.offered, .reserved), (.reserved, .onScreen), (.reserved, .ending),
             (.onScreen, .ending), (.ending, .ended):
            true
        default:
            false
        }
    }
}
