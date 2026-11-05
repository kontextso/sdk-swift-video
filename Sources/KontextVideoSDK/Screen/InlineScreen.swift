import UIKit

/// An overlay or pause ad inside the app's player view: the `InlineAdView` that holds the page, and the
/// `OnScreenTimeClock` that counts the time it is seen (and ends an overlay whose `duration` ran out on it).
/// Its placement (the app's insets, the size variant chosen at `show`) lives here too, read by
/// `InlineScreen+Placement` at `show` and at every layout pass.
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
    var meter: ViewabilityMeter?

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
    func configure() {
        guard let meter else { return }
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

    func tearDown() -> TimeInterval {
        let activeTime = onScreenClock?.stop() ?? 0
        meter?.stop()
        meter = nil
        hostView?.removeFromSuperview()
        hostView = nil
        return activeTime
    }

    /// Gone already: `tearDown` removed the host.
    func close(onGone: @escaping @MainActor (_ hasTimedOut: Bool) -> Void) -> Bool { false }
}
