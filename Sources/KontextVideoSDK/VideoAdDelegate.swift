import Foundation

/// The moments of an ad's life after `load` returned it, delivered on the main actor. Every method has an
/// empty default, so implement the ones you need. The delegate is held weakly, as every Apple delegate.
///
/// The guarantee: `load` returns a ready ad; `show` either throws or presentation begins; then the
/// impression and zero or more interaction callbacks; then exactly one terminal `videoAd(_:didEnd:)`,
/// whoever ended it (the viewer, the creative, the system, or the app with `dismiss()` or `destroy()`).
/// Resume your content in `didEnd`, whatever the reason. There is no "did show" callback: `show`
/// returning is that signal, and `didEnd` is delivered once, synchronously, even from inside your own
/// `dismiss()` or `destroy()` call, so the resume logic lives in `didEnd` alone.
@MainActor
public protocol VideoAdDelegate: AnyObject {
    // Before presentation

    /// A loaded ad can no longer be shown: it expired, targeting changed, its `VideoAds` was destroyed, or
    /// the creative died while waiting. `isReady` is `false`; `show` throws `.invalidated(reason)`.
    func videoAd(_ ad: VideoAd, didInvalidate reason: VideoAd.InvalidationReason)
    /// Timed mode: the ad's window opened, show it now (`show(in:)` for an overlay; pause the content and
    /// `show(from:)` for a linear ad). Not shown by the window's end: `didInvalidate(.windowPassed)`.
    func videoAdDidReachWindow(_ ad: VideoAd)

    // After a successful show, in order: the impression, then interactions, then exactly one didEnd

    /// The impression was counted: at `show` for an image, at the first frame of the ad video for a video
    /// (usually under a second after `show` returned; if it never comes, `didFail` then `didEnd(.failed)`).
    func videoAdDidRecordImpression(_ ad: VideoAd)
    /// The viewer tapped the ad; the SDK opened `click.url`. `click.area` says where (`creative`, `endCard`, ...).
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click)
    /// A rewarded linear ad completed: grant the reward.
    func videoAd(_ ad: VideoAd, didEarn reward: VideoAd.Reward)
    /// The creative failed or stalled after presentation began. `didEnd(.failed)` follows.
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError)
    /// Presentation is over. Exactly once per successful `show`.
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason)
}

public extension VideoAdDelegate {
    func videoAd(_ ad: VideoAd, didInvalidate reason: VideoAd.InvalidationReason) {}
    func videoAdDidReachWindow(_ ad: VideoAd) {}
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

    /// How an ad on screen ended: the outcome, not why a view went away.
    public enum EndReason: Sendable, Equatable {
        /// Linear: the video played to the end; the viewer closing the end card afterwards is still
        /// this, the close is only how a finished ad leaves the screen. Overlay: its `duration` elapsed and
        /// the SDK removed it.
        case completed
        /// The viewer skipped the video.
        case skipped
        /// Overlay or pause ad: the viewer tapped its close control before it ended on its own (a pause
        /// ad's close leaves the content paused; Resume is `.resumed`). Never for a linear ad: a close
        /// before the end is `.skipped`, after it `.completed`; the outcome, not the gesture.
        case closed
        /// The viewer tapped Resume on a full-screen pause ad.
        case resumed
        /// The creative failed or stalled; `didFail` came first.
        case failed
        /// The presentation disappeared for a reason the SDK did not cause: the presenting view controller
        /// was dismissed under it, the app navigated away, the viewer seeked out of an overlay's window.
        case interrupted
        /// The app called `dismiss()`.
        case dismissed
        /// The app called `destroy()` on the `VideoAds` while the ad was on screen.
        case destroyed
    }
}
