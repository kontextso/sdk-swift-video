import WebKit

/// A linear ad full screen: the `LinearAdViewController` UIKit presents, and its dismissal at the end
/// (`LinearPresentation`). No active time is counted: a linear ad has no `overlayViewDuration`.
@MainActor
final class LinearScreen: AdScreen {
    unowned let ad: VideoAd
    /// The controller presented for the ad; `nil` before `attach` and once its dismissal began.
    private(set) var controller: LinearAdViewController?
    var meter: ViewabilityMeter?

    init(ad: VideoAd) {
        self.ad = ad
    }

    var isInline: Bool { false }

    /// How long a linear ad may take to reach the screen before the ad gives up on it.
    static var showTimeout: TimeInterval = 2
    /// How long a dismissal may take before `didEnd` comes anyway, once the controller left the screen (five
    /// times that if not): a completion UIKit never calls must not keep the app waiting, nor one still running be cut.
    static var dismissalTimeout: TimeInterval = 1

    /// The view controller to present from: `viewController` when given, which must be on screen and not already
    /// presenting; with `nil`, the key window's top view controller. Throws `cannotShowNow` when none can present
    /// now, or the app or its scene is not in front; the ad stays ready.
    static func presenter(from viewController: UIViewController?, adId: String) throws -> UIViewController {
        let presenter: UIViewController
        if let viewController {
            guard ViewExposure.canBeSeen(viewController.view), viewController.presentedViewController == nil,
                  !viewController.isBeingPresented, !viewController.isBeingDismissed else {
                Logger.warning("ad \(adId.prefix(8)): cannot present, the view controller is not on screen or already presenting")
                throw VideoAdError.cannotShowNow
            }
            presenter = viewController
        } else {
            guard let top = LinearAdViewController.topPresenter(), ViewExposure.canBeSeen(top.view) else {
                Logger.warning("ad \(adId.prefix(8)): cannot present, no view controller on the key window can present now")
                throw VideoAdError.cannotShowNow
            }
            presenter = top
        }
        guard ViewExposure.isInFront(presenter.view) else {
            Logger.warning("ad \(adId.prefix(8)): cannot present, the app or the presenter's scene is not in front; the ad stays ready")
            throw VideoAdError.cannotShowNow
        }
        return presenter
    }

    /// The controller that shows `webView` full screen. UIKit taking it away (not the SDK) ends the ad.
    @discardableResult
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

    /// Presents the controller from `presenter`, with the show watchdog (`showTimeout`): `onPresented` once UIKit
    /// confirmed it (with the controller, which may be gone), `onFailed` when UIKit never put it on screen, while
    /// `isPending` holds.
    func present(from presenter: UIViewController, isPending: @escaping @MainActor () -> Bool,
                 onPresented: @escaping @MainActor (LinearAdViewController?) -> Void, onFailed: @escaping @MainActor () -> Void) {
        guard let controller else { return }
        LinearPresentation.present(controller, from: presenter, adId: ad.id, timeout: Self.showTimeout, isPending: isPending,
                                   onPresented: { [weak controller] in onPresented(controller) }, onFailed: onFailed)
    }

    /// A sheet over the ad (a click's store page) leaves its view in the window, where the meter would still
    /// see it whole, and makes UIKit remove the view until the sheet goes: neither is the ad leaving. Out of
    /// sight is no end either: the viewer's own doing, and it comes back.
    func configure() {
        meter?.isCovered = { [weak self] in self?.controller.map(Environment.isCovered) ?? false }
    }

    func reachedScreen() {}

    /// The controller stays, for `close`.
    func tearDown() -> TimeInterval {
        meter?.stop()
        meter = nil
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
        return LinearPresentation.dismiss(controller, timeout: Self.dismissalTimeout, isPending: isPending, completion: onGone)
    }
}
