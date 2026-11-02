import UIKit

/// One ad on screen, from `show` to `didEnd`: the app's one slot, what is on screen (an overlay's or pause
/// ad's host view, or a linear ad's controller) and what measures it (the viewability meter, the clock).
/// Made when `show` commits, released when `didEnd` is delivered; the slot is taken and freed here and
/// nowhere else, and `KontextVideo.adOnScreen` and the owner's showing ad follow it.
@MainActor
final class Presentation {
    /// Retained from `show` to `didEnd`, whatever the app does with its own reference.
    let ad: VideoAd
    private weak var owner: VideoAds?
    /// The view the SDK put into the player's view for an overlay or pause ad.
    var hostView: AdHostView?
    /// The controller the SDK presented for a linear ad; handed back for the dismissal at the end.
    var linearController: LinearViewController?
    /// Decides `viewable` / `notViewable` and reports exposure while the ad is on screen.
    var meter: ViewabilityMeter?
    /// Time seen on screen, for an overlay or pause ad; it also ends an overlay whose `duration` elapsed.
    var clock: ActiveTimeClock?

    private init(ad: VideoAd, owner: VideoAds?) {
        self.ad = ad
        self.owner = owner
    }

    /// `show` committed: the ad takes the app's one slot and its owner hears it is showing, before any of the
    /// app's code can run, so a show from inside that code finds the slot taken.
    static func begin(_ ad: VideoAd, owner: VideoAds?) -> Presentation {
        let presentation = Presentation(ad: ad, owner: owner)
        KontextVideo.shared.presentation = presentation
        owner?.adDidBeginShowing(ad)
        return presentation
    }

    /// The ad is ending: measuring stops and the inline page leaves the screen. Returns the active time seen,
    /// for `overlayViewDuration`. The linear controller stays for the ad to dismiss.
    func tearDown() -> TimeInterval {
        let activeTime = clock?.stop() ?? 0
        meter?.stop()
        meter = nil
        hostView?.removeFromSuperview()
        hostView = nil
        return activeTime
    }

    /// `didEnd` is next: the slot is free and the owner stops following the ad.
    func release() {
        if KontextVideo.shared.presentation === self { KontextVideo.shared.presentation = nil }
        owner?.adDidEnd(ad)
    }
}
