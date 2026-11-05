import UIKit
import WebKit

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

/// An overlay or pause ad inside the app's player view: the `InlineAdView` that holds the page, and the
/// `OnScreenTimeClock` that counts the time it is seen (and ends an overlay whose `duration` ran out on it).
/// Its placement (the app's insets, the size variant chosen at `show`) lives here too, read by
/// `VideoAd+Placement` at `show` and at every layout pass.
@MainActor
final class InlineScreen: AdScreen {
    unowned let ad: VideoAd
    /// The app's insets from `show(in:insets:)`, on top of the view's safe area, for every refit too; never
    /// negative or non-finite.
    let extraInsets: UIEdgeInsets
    /// The size variant `frame(in:safeArea:)` chose for the view at `show`: the largest that fits without
    /// scaling, else the one with the best scale still at or above 50 %. `nil` for a full-screen pause ad, or
    /// when none fitted.
    var chosenSize: VideoAd.Size?
    /// The view the SDK put into the player's view; `nil` before `attach` and after the end.
    private(set) var hostView: InlineAdView?
    /// Time seen on screen; made once the creative is on screen.
    private(set) var onScreenClock: OnScreenTimeClock?

    init(ad: VideoAd, extraInsets: UIEdgeInsets) {
        self.ad = ad
        self.extraInsets = extraInsets
    }

    var isInline: Bool { true }

    /// Puts `webView` into `container` at `adFrame`, inside a host over the whole container that follows its
    /// resizes. Adding the host runs the container's overridable hooks, the app's code: the host is known
    /// first, so an end from there finds and removes it.
    func attach(_ webView: UIView, to container: UIView, adFrame: CGRect, coversWhole: Bool) -> InlineAdView {
        let ad = self.ad
        let host = InlineAdView(frame: container.bounds, content: webView)
        host.coversWhole = coversWhole
        host.content.frame = adFrame
        host.place = { [weak self] bounds, safeArea in self?.refit(in: bounds, safeArea: safeArea) }
        host.onUnfit = { [weak ad] in
            // Not inside UIKit's layout pass: ending removes the view being laid out.
            Task { @MainActor [weak ad] in
                guard let ad, !ad.hasEnded else { return }
                Logger.warning("ad \(ad.id.prefix(8)): the view became too small for the ad; ended as interrupted")
                ad.end(.interrupted)
            }
        }
        hostView = host
        container.addSubview(host)
        return host
    }

    /// The meter is the one answer to "is it seen": the clock counts only then, and an ad out of sight in an
    /// active scene (a feed cell swiped away) ends, freeing the app's slot.
    func configure(meter: ViewabilityMeter) {
        meter.onSeen = { [weak self] seen in self?.onScreenClock?.setSeen(seen) }
        let ad = self.ad
        meter.onOffScreen = { [weak ad] in
            guard let ad, !ad.hasEnded else { return }
            Logger.warning("ad \(ad.id.prefix(8)): out of sight for \(ViewabilityMeter.offScreenGrace) s; ended as interrupted")
            ad.end(.interrupted)
        }
    }

    /// The clock starts, with the duration the ad's content rule chose, and the rule starts following the
    /// content with it.
    func reachedScreen() {
        let ad = self.ad
        let clock = OnScreenTimeClock(duration: ad.contentRule.wallClockDuration, adId: ad.id) { [weak ad] in
            guard let ad, !ad.hasEnded else { return }
            Logger.debug("ad \(ad.id.prefix(8)): overlay duration of \(ad.duration ?? 0) s on screen elapsed")
            ad.state.markCompleted()
            ad.end(.completed)
        }
        onScreenClock = clock
        clock.setSeen(ad.meter?.isSeen ?? true)
        clock.start(in: hostView?.window)
        ad.contentRule.started(onScreenClock: clock)
    }

    func tearDown(meter: ViewabilityMeter?) -> TimeInterval {
        let activeTime = onScreenClock?.stop() ?? 0
        meter?.stop()
        hostView?.removeFromSuperview()
        hostView = nil
        return activeTime
    }

    /// Gone already: `tearDown` removed the host.
    func close(onGone: @escaping @MainActor (_ hasTimedOut: Bool) -> Void) -> Bool { false }
}

/// A linear ad full screen: the `LinearAdViewController` UIKit presents, and its dismissal at the end
/// (`LinearPresentation`). No active time is counted: a linear ad has no `overlayViewDuration`.
@MainActor
final class LinearScreen: AdScreen {
    unowned let ad: VideoAd
    /// The controller presented for the ad; `nil` before `attach` and once its dismissal began.
    private(set) var controller: LinearAdViewController?

    init(ad: VideoAd) {
        self.ad = ad
    }

    var isInline: Bool { false }

    /// The controller that shows `webView` full screen. UIKit taking it away (not the SDK) ends the ad.
    func attach(_ webView: WKWebView) -> LinearAdViewController {
        let ad = self.ad
        let controller = LinearAdViewController(webView: webView)
        controller.onInterrupted = { [weak ad] in
            guard let ad else { return }
            Logger.warning("ad \(ad.id.prefix(8)): presentation interrupted")
            ad.end(.interrupted)
        }
        self.controller = controller
        return controller
    }

    /// A sheet over the ad (a click's store page) leaves its view in the window, where the meter would still
    /// see it whole, and makes UIKit remove the view until the sheet goes: neither is the ad leaving. Out of
    /// sight is no end either: the viewer's own doing, and it comes back.
    func configure(meter: ViewabilityMeter) {
        meter.isCovered = { [weak self] in self?.controller.map(Environment.isCovered) ?? false }
    }

    func reachedScreen() {}

    /// The controller stays, for `close`.
    func tearDown(meter: ViewabilityMeter?) -> TimeInterval {
        meter?.stop()
        return 0
    }

    /// Whatever the reason, while UIKit still presents it; `didEnd` waits, so a screen presented there misses
    /// the animation.
    func close(onGone: @escaping @MainActor (_ hasTimedOut: Bool) -> Void) -> Bool {
        guard let controller else { return false }
        self.controller = nil
        // Pending while the ad is ending: once `didEnd` was delivered, the watchdog has nothing left to do.
        let isPending: @MainActor () -> Bool = { [weak ad] in
            if case .ending? = ad?.state.phase { return true }
            return false
        }
        return LinearPresentation.dismiss(controller, timeout: VideoAd.dismissalTimeout, isPending: isPending, completion: onGone)
    }
}
