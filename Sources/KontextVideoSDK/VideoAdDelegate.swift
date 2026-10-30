/// The moments of an ad on screen, delivered on the main actor. Every method has an empty default, so
/// implement the ones you need. The delegate is held weakly, as every Apple delegate.
///
/// Nothing is delivered before `show`: an ad that can no longer be shown says so when `load()` or `show`
/// throws. `show` either throws, and nothing happened, or the presentation is accepted: an overlay or
/// pause ad is on screen when it returns (an image or HTML creative's impression may even arrive inside
/// `show(in:)`); a linear ad has asked UIKit to present it, which can still fail, as `didFail` then says.
/// After that: the impression (at most once, maybe never) and any interactions; then exactly one terminal
/// `videoAd(_:didEnd:)`, whoever ended it (the viewer, the creative, the system, or the app with `dismiss()`
/// or `destroy()`). There is no "did show" callback: `show` returning is that signal.
///
/// Put the clean-up after an ad in `didEnd`, and decide playback there from the format, the reason and
/// whether that content is still current: a linear ad's end is normally where the content resumes; a
/// pause ad closed with ✕ (`.closed`) leaves the content paused, Resume (`.resumed`) means play; after
/// `.destroyed` the viewer has usually left. `didEnd` is delivered once: for an overlay or pause ad
/// synchronously, even from inside your own `dismiss()` or `destroy()` call; for a linear ad once its
/// dismissal finished (as AdMob's and MAX's "dismissed" callbacks), so the next screen can be presented
/// from it. Should UIKit never finish that dismissal, `didEnd` still comes after a bounded wait.
@MainActor
public protocol VideoAdDelegate: AnyObject {
    // After a successful show: the impression and interactions, in no guaranteed order; didEnd last

    /// The impression was counted: when an image or HTML creative is shown, at the first frame of the ad
    /// video for a video. It may never come: the ad can end before (skipped, dismissed, destroyed,
    /// interrupted, failed).
    func videoAdDidRecordImpression(_ ad: VideoAd)
    /// The viewer tapped the ad and the SDK took the click: it fired the click beacons and is opening the
    /// target (the URL, its fallback when the first cannot open, or the App Store sheet for an app-install
    /// ad). Neither which target opened nor whether it did is reported, as with AdMob and MAX. `click.area`
    /// says where the viewer tapped. Once per tap.
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click)
    /// The ad broke after `show` returned: the creative failed or stalled, or UIKit never presented a
    /// linear ad (`presenterUnavailable`). `didEnd(.failed)` follows once the ad is cleaned up (for a
    /// linear ad, after its dismissal).
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError)
    /// Presentation is over. Exactly once per successful `show`.
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason)
}

/// Empty defaults: implement only the moments you need.
public extension VideoAdDelegate {
    func videoAdDidRecordImpression(_ ad: VideoAd) {}
    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {}
    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {}
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {}
}

extension VideoAd {
    /// A tap on the ad. A struct rather than loose parameters so fields can be added without renaming the
    /// delegate method. It carries no URL: the page's target is the advertiser's tracking link, often not
    /// what opened (a fallback, the App Store sheet), and the SDK has already opened it.
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
        /// The ad broke after `show` returned: the creative failed or stalled, or UIKit never presented a
        /// linear ad; `didFail` came first.
        case failed
        /// The presentation disappeared for a reason the SDK did not cause: the presenting view controller
        /// was dismissed under a linear ad, the view holding an overlay or pause ad left the window (the
        /// app navigated away without `dismiss()`), or that view became too small for the ad (it shrank or
        /// rotated). A view that left is noticed within about two measuring intervals (0.5 s). For an overlay
        /// with a player tracked by `track(_:)`, also the content pausing, ending or moving to another item.
        case interrupted
        /// The app called `dismiss()`.
        case dismissed
        /// The app called `destroy()` on the `VideoAds` while the ad was on screen.
        case destroyed
    }
}
