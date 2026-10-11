import Foundation

/// The moments of an ad's life after `load` returned it, delivered on the main actor. Every method has an
/// empty default, so implement the ones you need. The delegate is held weakly, as every Apple delegate.
///
/// The guarantee: `load` returns a ready ad; `show` either throws or presentation begins; then zero or
/// more interaction callbacks; then exactly one terminal `videoAd(_:didEnd:)`, whoever ended it (the
/// viewer, the creative, the system, or the app with `dismiss()` or `destroy()`). Resume your content in
/// `didEnd`, whatever the reason.
@MainActor
public protocol VideoAdDelegate: AnyObject {
    // Before presentation

    /// A loaded ad can no longer be shown: it expired, targeting changed, its `VideoAds` was destroyed, or
    /// the creative died while waiting. `isReady` is `false`; `show` throws `.invalidated(reason)`.
    func videoAd(_ ad: VideoAd, didInvalidate reason: VideoAd.InvalidationReason)

    // After a successful show, in order: didShow, then interactions, then exactly one didEnd

    /// Presentation began: the ad is on screen.
    func videoAdDidShow(_ ad: VideoAd)
    /// The impression was counted: at `didShow` for an image, at the first frame for a video.
    func videoAdDidRecordImpression(_ ad: VideoAd)
    /// The viewer tapped the ad; the SDK opened `click.url`. `click.area` says where (`creative`, `endCard`, ...).
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click)
    /// A rewarded interstitial completed: grant the reward.
    func videoAd(_ ad: VideoAd, didEarn reward: VideoAd.Reward)
    /// The creative failed or stalled after presentation began. `didEnd(.failed)` follows.
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError)
    /// Presentation is over. Exactly once per successful `show`.
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason)
}

public extension VideoAdDelegate {
    func videoAd(_ ad: VideoAd, didInvalidate reason: VideoAd.InvalidationReason) {}
    func videoAdDidShow(_ ad: VideoAd) {}
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
        /// Interstitial: the video completed and the end card, if any, was closed. Overlay: its
        /// `duration` elapsed and the SDK removed it.
        case completed
        /// The viewer skipped the video.
        case skipped
        /// The viewer used the close control.
        case closed
        /// The viewer tapped Resume on a full-screen pause ad.
        case resumed
        /// The creative failed or stalled; `didFail` came first.
        case failed
        /// The presentation disappeared for a reason the SDK did not cause.
        case interrupted
        /// The app called `dismiss()`.
        case dismissed
        /// The app called `destroy()` on the `VideoAds` while the ad was on screen.
        case destroyed
    }
}
