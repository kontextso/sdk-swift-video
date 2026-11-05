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

    /// The player's view the ad goes into, and where in it; set by `prepare`.
    private weak var container: UIView?
    private var adFrame: CGRect = .zero

    init(ad: VideoAd, extraInsets: UIEdgeInsets) {
        self.ad = ad
        self.extraInsets = extraInsets
    }

    /// The checks and the placement of an overlay or pause ad in `view`, before anything is reserved: the view must
    /// be on screen and in front of the viewer, and the ad must fit it (`frame(in:safeArea:)`). Throws
    /// `cannotShowNow` or `containerTooSmall`, with nothing fired; the ad stays ready.
    static func prepare(for ad: VideoAd, in view: UIView, insets: UIEdgeInsets) throws -> InlineScreen {
        guard ViewExposure.canBeSeen(view) else {
            Logger.warning("ad \(ad.id.prefix(8)): cannot show, the view is not on screen or is hidden")
            throw VideoAdError.cannotShowNow
        }
        guard ViewExposure.isInFront(view) else {
            Logger.warning("ad \(ad.id.prefix(8)): cannot show, the app or the view's scene is not in front; the ad stays ready")
            throw VideoAdError.cannotShowNow
        }
        let area = CGRect(origin: .zero, size: view.bounds.size)
        let screen = InlineScreen(ad: ad, extraInsets: AdGeometry.cleaned(insets))
        screen.adFrame = ad.descriptor.position == .fullscreen
            ? screen.fullscreenFrame(in: area, safeArea: view.safeAreaInsets)
            : try screen.frame(in: area, safeArea: AdGeometry.adding(screen.extraInsets, to: view.safeAreaInsets))
        screen.container = view
        return screen
    }

    /// Puts `webView` into the prepared view at the prepared frame, inside a host over the whole view that follows
    /// its resizes. Adding the host runs the view's overridable hooks, the app's code: the host is known first, so
    /// an end from there finds and removes it. Returns whether anything of the ad is on screen where it was placed
    /// (the hook's doing, or a feed showing the player's middle, not its top card, can leave nothing).
    func attach(_ webView: UIView) -> Bool {
        guard let container else { return false }
        let ad = self.ad
        let host = InlineAdView(frame: container.bounds, content: webView)
        host.coversWhole = ad.descriptor.position == .fullscreen
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
        return ViewExposure.canBeSeen(host) && ViewExposure.visibleShare(of: webView) > 0
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
