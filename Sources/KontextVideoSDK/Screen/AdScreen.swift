import UIKit

/// Where an ad is on screen, by format: inside the app's player view (`InlineScreen`, an overlay or pause
/// ad) or full screen over the app (`LinearScreen`, a linear ad).
///
/// Why: the two differ in everything about the screen: what holds the page, how the ad leaves, what the
/// viewability meter must know, whether active time is counted. Each lives in its own type, so `VideoAd`
/// never asks "which format am I?" about the screen.
///
/// ```
///                 holds the page              measures                       leaves the screen
/// InlineScreen    InlineAdView in the player  meter + OnScreenTimeClock;       removed at once: didEnd now
///                                             out of sight 1 s ends it
/// LinearScreen    LinearAdViewController      meter; a sheet over it         dismissed through UIKit:
///                 presented full screen       counts as covered              didEnd once it is gone
/// ```
///
/// How: `show(in:)` makes an `InlineScreen` and `show(from:)` a `LinearScreen` when the ad takes the app's
/// slot (`ShownAd`); then:
/// 1. `show` attaches the page to it (`attach`);
/// 2. once the creative is on screen, the meter is set up for it (`configure(meter:)`) and it starts what it
///    counts (`reachedScreen()`);
/// 3. at the end, `VideoAd.end(_:)` tears it down (`tearDown(meter:)`: the active time seen) and closes it
///    (`close(onGone:)`: `true` when `didEnd` must wait for the screen to be gone).
/// A screen ends its ad only through `VideoAd.end(_:)`, never by finishing it itself.
@MainActor
protocol AdScreen: AnyObject {
    /// The ad sits in the app's player view: its active time is counted and reported (`overlayViewDuration`).
    var isInline: Bool { get }
    /// Sets the meter up for this screen, before it starts.
    func configure(meter: ViewabilityMeter)
    /// The creative is on screen, the meter running: the screen starts what it counts.
    func reachedScreen()
    /// The ad is ending: the clock, then `meter`, then the page leave the screen. Returns the active time
    /// seen, seconds.
    func tearDown(meter: ViewabilityMeter?) -> TimeInterval
    /// Takes the screen away after `tearDown`. Returns `true` when that takes time: `onGone` runs once it
    /// finished (`hasTimedOut`: reported over a screen UIKit did not take down), and `didEnd` waits for it.
    /// `false`: nothing to wait for, `onGone` never runs.
    func close(onGone: @escaping @MainActor (_ hasTimedOut: Bool) -> Void) -> Bool
}
