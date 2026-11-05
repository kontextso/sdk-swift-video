/// The app's one ad on screen, from any `VideoAds`: taken when `show` commits, freed when `didEnd` is delivered.
/// The slot is taken and freed here and nowhere else.
///
/// Why one slot: two ads on screen at once would cover each other and split the viewer's attention the server
/// paid for; a second `show` throws `anotherAdShowing` while the slot is taken. The slot also retains its ad from
/// `show` to `didEnd`, whatever the app does with its own reference, so the ad can finish what it started.
///
/// ```
/// show commits ── take(ad, owner) ──► current = ad, the owner follows it (adDidBeginShowing)
///   … on screen …
/// didEnd next ── release(ad) ───────► current = nil, the owner stops following it (adDidEnd)
/// ```
///
/// Taken before any of the app's code can run (the hooks UIKit calls as the ad goes on screen, the delegate), so a
/// `show` from inside that code finds it taken. `VideoAd` takes and releases it; `KontextVideo.adOnScreen` reads it.
@MainActor
enum ScreenSlot {
    /// The ad on screen; `nil` when the slot is free.
    private(set) static var current: VideoAd?

    /// `show` committed: `ad` takes the slot and `owner` hears it is showing.
    static func take(_ ad: VideoAd, owner: VideoAds?) {
        current = ad
        owner?.adDidBeginShowing(ad)
    }

    /// `didEnd` is next: the slot is free, if `ad` held it, and its owner stops following it.
    static func release(_ ad: VideoAd, owner: VideoAds?) {
        if current === ad { current = nil }
        owner?.adDidEnd(ad)
    }

    /// The slot free, with nothing told. Tests only: the slot is process-wide.
    static func resetForTesting() { // swiftlint:disable:this unused_declaration
        current = nil
    }
}
