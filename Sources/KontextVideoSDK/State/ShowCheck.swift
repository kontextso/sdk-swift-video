/// Whether a `show` may begin, and if not, why: the checks in the order they run, over plain facts. The first
/// that fails is the refusal the app gets; nothing is fired.
///
/// ```
///   #  check                                        refusal
///   1  shown before                                 alreadyShown
///   2  its VideoAds destroyed or released           destroyed
///   3  the SDK switched off                         disabled
///   4  ended before show (rejected, expired, ...)   invalidated
///   5  expired now                                  expired (the ad ends as expired)
///   6  its episode no longer plays                  contentChanged (the ad ends as contentChanged)
///   7  another ad on screen                         anotherAdShowing
///   8  not loaded                                   notLoaded
///   9  an overlay over paused content               contentPaused (the ad stays ready)
/// ```
///
/// `VideoAd` gathers the facts after the app code a show runs first (an ad over stopped content ends, the player is
/// read) and carries out the refusal: ending the ad for 5 and 6, then throwing.
enum ShowCheck {
    /// Why a show is refused.
    enum Refusal: Equatable {
        case alreadyShown, destroyed, disabled(reason: String), invalidated(VideoAd.InvalidationReason), expired
        case contentChanged, anotherAdShowing, notLoaded, contentPaused
    }

    /// What the checks read. `playsAnotherEpisode` is read only when every check before it passed: it asks the
    /// app's player.
    struct Facts {
        var wasShown = false
        var isOwnerGone = false
        var disabledReason: String?
        var invalidationReason: VideoAd.InvalidationReason?
        var isExpired = false
        var playsAnotherEpisode: () -> Bool = { false }
        var isSlotTaken = false
        var isLoaded = true
        var isContentPaused = false
    }

    /// The first check that fails, or `nil` when the show may begin.
    static func refusal(_ facts: Facts) -> Refusal? {
        if facts.wasShown { return .alreadyShown }
        if facts.isOwnerGone { return .destroyed }
        if let reason = facts.disabledReason { return .disabled(reason: reason) }
        if let reason = facts.invalidationReason { return .invalidated(reason) }
        if facts.isExpired { return .expired }
        if facts.playsAnotherEpisode() { return .contentChanged }
        if facts.isSlotTaken { return .anotherAdShowing }
        if !facts.isLoaded { return .notLoaded }
        if facts.isContentPaused { return .contentPaused }
        return nil
    }
}
