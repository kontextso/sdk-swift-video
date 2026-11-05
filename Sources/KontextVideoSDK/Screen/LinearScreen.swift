import UIKit
import WebKit

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
