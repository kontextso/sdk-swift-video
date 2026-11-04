import Foundation

/// One ad on screen, from `show` to `didEnd`: the app's one slot, the screen it is on (`AdScreen`: an
/// overlay's or pause ad's host view and clock, or a linear ad's controller) and the viewability meter.
/// Made when `show` commits, released when `didEnd` is delivered; the slot is taken and freed here and
/// nowhere else, and `KontextVideo.adOnScreen` and the owner's showing ad follow it.
@MainActor
final class Presentation {
    /// Retained from `show` to `didEnd`, whatever the app does with its own reference.
    let ad: VideoAd
    private weak var owner: VideoAds?
    /// Where the ad is: inside the player's view or full screen; chosen by the `show` call.
    let screen: any AdScreen
    /// Decides `viewable` / `notViewable` and reports exposure while the ad is on screen.
    var meter: ViewabilityMeter?

    private init(ad: VideoAd, owner: VideoAds?, screen: any AdScreen) {
        self.ad = ad
        self.owner = owner
        self.screen = screen
    }

    /// `show` committed: the ad takes the app's one slot and its owner hears it is showing, before any of the
    /// app's code can run, so a show from inside that code finds the slot taken.
    static func begin(_ ad: VideoAd, owner: VideoAds?, screen: any AdScreen) -> Presentation {
        let presentation = Presentation(ad: ad, owner: owner, screen: screen)
        KontextVideo.shared.presentation = presentation
        owner?.adDidBeginShowing(ad)
        return presentation
    }

    /// The ad is ending: measuring stops and an inline page leaves the screen. Returns the active time seen,
    /// for `overlayViewDuration`. A linear controller stays for the screen to close.
    func tearDown() -> TimeInterval {
        let activeTime = screen.tearDown(meter: meter)
        meter = nil
        return activeTime
    }

    /// `didEnd` is next: the slot is free and the owner stops following the ad.
    func release() {
        if KontextVideo.shared.presentation === self { KontextVideo.shared.presentation = nil }
        owner?.adDidEnd(ad)
    }
}
