/// Everything about where an ad is in its life, as one plain value: its phase, the milestones it passed
/// (loaded, impression, completed, on screen, the failure behind its end) and the flags the public API reads
/// off them. One source of truth: every fact of an ad's life lives here, and everyone else (`VideoAd`'s public
/// flags, the screens, the content rules, the page's handlers) asks it. The rules it follows are
/// `AdLifecycle`'s.
///
/// The ad's state is not its page's (`PageState`, moved by `FrameProtocol`), and both are needed: the page's
/// rules are checked before the ad hears a message; the page can end itself before the ad knows; a page can be
/// loaded for an ad only offered; an ad can be reserved while its page is not shown yet. They move together at
/// fixed points: the page's `ad.loaded` marks the ad loaded; the ad reaching the screen (`onScreen`) shows the
/// page; a page that ends itself hands the ad its event and the ad ends; the ad's end or invalidation hides the
/// page.
///
/// How: `VideoAd` holds one `AdState` and moves it only through `moveTo(_:)`, which asks
/// `AdLifecycle.canMove(from:to:)` and says whether it moved; an illegal move (a late event, a second end)
/// changes nothing, and the caller stops there. A milestone is set through its `mark` method (or, for
/// `wasOnScreen`, by the first move to `onScreen`), once, and never undone; a `mark` does not move the phase.
/// Every public flag of the ad reads the state live, never a copy.
///
/// | Phase | `wasShown` | `hasEnded` | `invalidationReason` | `wasOnScreen` |
/// |---|---|---|---|---|
/// | offered | `false` | `false` | `nil` | `false` |
/// | invalidated | `false` | `false` | set | `false` |
/// | reserved | `true` | `false` | `nil` | `false` |
/// | onScreen | `true` | `false` | `nil` | `true` |
/// | ending, ended | `true` | `true` | `nil` | as it was |
struct AdState: Equatable {
    private(set) var phase = AdLifecycle.Phase.offered
    /// The creative reached the screen (the phase became `onScreen`). Stays `true` after the end: an ad that was
    /// on screen without an impression closes.
    private(set) var wasOnScreen = false

    /// The page reported the creative ready (`isLoaded`).
    private(set) var isLoaded = false
    /// The impression fired: at `show` for an image, at the first frame for a video.
    private(set) var hasImpression = false
    /// The creative ran to its end (`isCompleted`).
    private(set) var isCompleted = false
    /// What broke, for the `didFail` that `end(.failed)` delivers first.
    private(set) var failure: VideoAdError?

    /// Records that the creative is ready. Once; never undone.
    mutating func markLoaded() { isLoaded = true }

    /// Records that the creative ran to its end. Once; never undone.
    mutating func markCompleted() { isCompleted = true }

    /// Records the impression, and says whether this was the first time: only then does it fire.
    mutating func markImpression() -> Bool {
        guard !hasImpression else { return false }
        hasImpression = true
        return true
    }

    /// Records what broke, for the `didFail` before `didEnd(.failed)`. The first failure stays.
    mutating func markFailed(_ error: VideoAdError) {
        if failure == nil { failure = error }
    }

    /// Moves to `next` when `AdLifecycle` allows it, and says whether it did; the first move to `onScreen`
    /// records `wasOnScreen`. A refused move changes nothing.
    @discardableResult
    mutating func moveTo(_ next: AdLifecycle.Phase) -> Bool {
        guard AdLifecycle.canMove(from: phase, to: next) else { return false }
        phase = next
        if next == .onScreen { wasOnScreen = true }
        return true
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
