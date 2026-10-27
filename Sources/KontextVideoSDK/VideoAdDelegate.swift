import Foundation

/// The moments of an ad on screen, delivered on the main actor. Every method has an empty default, so
/// implement the ones you need. The delegate is held weakly, as every Apple delegate.
///
/// Nothing is delivered before `show`: an ad that can no longer be shown says so when
/// `load()` or `show` throws. The guarantee: `show` either throws or the ad is on screen; then the
/// impression (at most once, maybe never) and any interactions; then exactly one terminal `videoAd(_:didEnd:)`,
/// whoever ended it (the viewer, the creative, the system, or the app with `dismiss()` or `destroy()`).
/// Resume your content in `didEnd`, whatever the reason. There is no "did show" callback: `show`
/// returning is that signal. `didEnd` is delivered once: for an overlay or pause ad synchronously, even
/// from inside your own `dismiss()` or `destroy()` call; for a linear ad once its dismissal animation
/// finished (as AdMob's and MAX's "dismissed" callbacks), so presenting your next screen from it is safe.
/// Either way the resume logic lives in `didEnd` alone.
@MainActor
public protocol VideoAdDelegate: AnyObject {
    // After a successful show: the impression and interactions, in no guaranteed order; didEnd last

    /// The impression was counted: at `show` for an image, at the first frame of the ad video for a video
    /// (usually under a second after `show` returned; if it never comes, `didFail` then `didEnd(.failed)`).
    func videoAdDidRecordImpression(_ ad: VideoAd)
    /// The viewer tapped the ad; the SDK opened `click.url`. `click.area` says where. Once per tap.
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click)
    /// The creative failed or stalled after presentation began. `didEnd(.failed)` follows right away.
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError)
    /// Presentation is over. Exactly once per successful `show`.
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason)
}

public extension VideoAdDelegate {
    func videoAdDidRecordImpression(_ ad: VideoAd) {}
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {}
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {}
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {}
}

extension VideoAd {
    /// A tap on the ad. A struct rather than loose parameters so fields can be added without renaming the
    /// delegate method.
    public struct Click: Sendable, Equatable {
        /// Where the viewer tapped.
        public enum Area: Sendable, Equatable {
            /// The creative itself: the image, the video, the card.
            case creative
            /// A linear ad's end card, after the video completed.
            case endCard
            /// A label of the page's own (`cta`, `logo`, ...), passed through unchanged.
            case other(String)

            /// From the page's `area`: absent is the creative.
            init(_ raw: String?) {
                switch raw {
                case nil, "creative": self = .creative
                case "endCard": self = .endCard
                case let label?: self = .other(label)
                }
            }
        }

        /// What the SDK opened.
        public let url: URL
        /// Where the viewer tapped.
        public let area: Area
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
        /// was dismissed under a linear ad, the view holding an overlay or pause ad left the window (the
        /// app navigated away without `dismiss()`). Noticed within about two measuring intervals (0.5 s).
        case interrupted
        /// The app called `dismiss()`.
        case dismissed
        /// The app called `destroy()` on the `VideoAds` while the ad was on screen.
        case destroyed
    }
}
