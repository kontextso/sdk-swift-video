import Foundation

/// The moments of an ad on screen, delivered on the main actor. Every method has an empty default, so
/// implement the ones you need. The delegate is held weakly, as every Apple delegate.
///
/// Nothing is delivered before `show`: a bid or a loaded ad that can no longer be shown says so when
/// `load()` or `show` throws. The guarantee: `show` either throws or the ad is on screen; then the
/// impression (at most once, maybe never) and any interactions; then exactly one terminal `videoAd(_:didEnd:)`,
/// whoever ended it (the viewer, the creative, the system, or the app with `dismiss()` or `destroy()`).
/// Resume your content in `didEnd`, whatever the reason. There is no "did show" callback: `show`
/// returning is that signal, and `didEnd` is delivered once, synchronously, even from inside your own
/// `dismiss()` or `destroy()` call, so the resume logic lives in `didEnd` alone.
@MainActor
public protocol VideoAdDelegate: AnyObject {
    // After a successful show: the impression and interactions, in no guaranteed order; didEnd last

    /// The impression was counted: at `show` for an image, at the first frame of the ad video for a video
    /// (usually under a second after `show` returned; if it never comes, `didFail` then `didEnd(.failed)`).
    func videoAdDidRecordImpression(_ ad: VideoAd)
    /// The viewer tapped the ad; the SDK opened `click.url`. `click.area` says where (`creative`, `endCard`, ...).
    /// Once per tap.
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click)
    /// A rewarded linear ad completed: grant the reward.
    func videoAd(_ ad: VideoAd, didEarn reward: VideoAd.Reward)
    /// The creative failed or stalled after presentation began. `didEnd(.failed)` follows right away.
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError)
    /// Presentation is over. Exactly once per successful `show`.
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason)
}

public extension VideoAdDelegate {
    func videoAdDidRecordImpression(_ ad: VideoAd) {}
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {}
    func videoAd(_ ad: VideoAd, didEarn reward: VideoAd.Reward) {}
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {}
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {}
}

extension VideoAd {
    /// A tap on the ad. A struct rather than loose parameters so fields can be added without renaming the
    /// delegate method.
    public struct Click: Sendable, Equatable {
        /// What the SDK opened.
        public let url: URL
        /// Where the viewer tapped, as the creative names it: `creative`, `endCard`, or its own value.
        public let area: String
    }

    /// How an ad on screen ended: who or what took it off the screen. Whether the creative ran to its
    /// end is a separate fact, `isCompleted`, so the same gesture gives the same reason in every format:
    /// a linear ad whose end card the viewer closes is `.closed` with `isCompleted == true`.
    public enum EndReason: Sendable, Equatable {
        /// The ad ended by itself, nobody touched it: an overlay's `duration` elapsed and the SDK removed
        /// it; a linear ad without an end card ended after its video completed.
        case completed
        /// The viewer tapped a linear ad's Skip (or close) before the video ended.
        case skipped
        /// The viewer tapped the ad's close control: an overlay's or pause card's ✕ (a pause ad's ✕ leaves
        /// the content paused; Resume is `.resumed`), or a linear ad's end card ✕ after the video completed.
        case closed
        /// The viewer tapped Resume on a full-screen pause ad.
        case resumed
        /// The creative failed or stalled; `didFail` came first.
        case failed
        /// The presentation disappeared for a reason the SDK did not cause: the presenting view controller
        /// was dismissed under it, the app navigated away.
        case interrupted
        /// The app called `dismiss()`.
        case dismissed
        /// The app called `destroy()` on the `VideoAds` while the ad was on screen.
        case destroyed
    }
}
