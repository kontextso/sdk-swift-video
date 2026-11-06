import StoreKit
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
    /// be on screen (some of it inside its window) and in front of the viewer, and the ad must fit it (`frame(in:safeArea:)`). Throws
    /// `cannotShowNow` or `containerTooSmall`, with nothing fired; the ad stays ready.
    static func prepare(for ad: VideoAd, in view: UIView, insets: UIEdgeInsets) throws -> InlineScreen {
        guard ViewExposure.canBeSeen(view) else {
            Logger.warning("ad \(ad.id.prefix(8)): cannot show, the view is not on screen or is hidden")
            throw VideoAdError.cannotShowNow
        }
        // In a window is not on screen: a pager's neighbour page, a view scrolled away. The impression would
        // count for nobody: refused, the ad ready. A view partly on screen is accepted; nothing of the ad seen
        // where it is placed then ends it at `attach`.
        guard ViewExposure.visibleShare(of: view) > 0 else {
            Logger.warning("ad \(ad.id.prefix(8)): cannot show, no part of the view is inside its window (a neighbour page, scrolled away); the ad stays ready")
            throw VideoAdError.cannotShowNow
        }
        guard ViewExposure.isInFront(view) else {
            Logger.warning("ad \(ad.id.prefix(8)): cannot show, the app or the view's scene is not in front; the ad stays ready")
            throw VideoAdError.cannotShowNow
        }
        guard coveringPresentation(over: view) == nil else {
            Logger.warning("ad \(ad.id.prefix(8)): cannot show, another screen of the app covers the view's; the ad stays ready")
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
        armUnfit(host)
        hostView = host
        container.addSubview(host)
        return ViewExposure.canBeSeen(host) && ViewExposure.visibleShare(of: webView) > 0
    }

    /// How long a view too small for the ad may stay so before the ad ends: containers pass through small sizes
    /// on their way to a bigger one (a SwiftUI transition, a Split View drag, a collapsing header). Tests shorten it.
    static var unfitGrace: TimeInterval = 0.5

    /// A layout pass where the ad no longer fits: after `unfitGrace` (not inside UIKit's layout pass, where ending
    /// would remove the view being laid out) the fit is asked again; still too small, the ad ends `.interrupted`;
    /// fitting again, it is placed and the next misfit is watched for the same way.
    private func armUnfit(_ host: InlineAdView) {
        host.onUnfit = { [weak self, weak host] in
            Task { @MainActor [weak self, weak host] in
                try? await Task.sleep(seconds: Self.unfitGrace)
                guard let self, !ad.hasEnded else { return }
                if let host, let player = host.superview, let frame = host.place?(host.bounds, player.safeAreaInsets) {
                    host.content.frame = frame
                    armUnfit(host)
                    return
                }
                Logger.warning("ad \(ad.id.prefix(8)): the view stayed too small for the ad for \(Self.unfitGrace) s; ended as interrupted")
                ad.end(.interrupted)
            }
        }
    }

    /// The meter is the one answer to "is it seen": the clock counts only then, and an ad out of sight in an
    /// active scene (a feed cell swiped away) ends, freeing the app's slot.
    func configure() {
        guard let meter else { return }
        meter.onSeen = { [weak self] seen in self?.onScreenClock?.setSeen(seen) }
        let ad = self.ad
        // UIKit has no event for a controller presented over another: the meter's tick asks.
        meter.onTick = { [weak self] in
            guard let self, !ad.hasEnded, let container, Self.coveringPresentation(over: container) != nil else { return }
            Logger.warning("ad \(ad.id.prefix(8)): another screen of the app covers the ad's; ended as interrupted")
            ad.end(.interrupted)
        }
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

    /// A controller the app presented over the one holding `view`, or over one of its parents: a sheet, a form
    /// sheet, a full-screen cover, a screen over the current context. The viewer left the player for another
    /// screen of the app, as another Activity covering the player's on Android. Not an alert or a popover: the
    /// player stays in view around them, as around an Android dialog, which does not stop the Activity. Not the
    /// App Store sheet an ad's click opens either: on Android a click leaves the app, which only freezes the ad.
    /// Nor one being dismissed. A view in no controller's view (added to the window itself) follows the window's
    /// root controller.
    static func coveringPresentation(over view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        var controller = responder as? UIViewController ?? ViewExposure.window(of: view)?.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController, !presented.isBeingDismissed, hidesThePlayer(presented) {
                return presented
            }
            controller = current.parent
        }
        return nil
    }

    private static func hidesThePlayer(_ presented: UIViewController) -> Bool {
        Environment.covers(presented) && presented.modalPresentationStyle != .popover && !(presented is SKStoreProductViewController)
    }

    /// Gone already: `tearDown` removed the host.
    func close(onGone: @escaping @MainActor (_ hasTimedOut: Bool) -> Void) -> Bool { false }
}
