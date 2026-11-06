import SafariServices
import UIKit

/// The in-app browser one ad's click opened over the app: an `SFSafariViewController`, and whether it is still up.
///
/// Why: a web link opened in Safari sends the app to the background, and the ad freezes there; opened here, the app
/// stays in front and the ad is only covered. Its own browser must not end it the way another screen of the app
/// does, and while the browser is up the ad is not seen: its clocks and its viewability wait for "Done".
///
/// ```
/// click ─ open: browser presented ─ isOpen ─ the viewer taps Done ─ closed: the ad goes on
///            inline: not a cover (InlineScreen), not seen (its meter): clocks and viewability frozen
///            linear: covered (LinearScreen): exposure 0, the page pauses its video, and plays it on again
/// ```
///
/// One per `VideoAd`, opened by `LinkOpener` for a `.web` link no app claimed; the screens ask `isOpen` and
/// `controller`. The UIKit presentation is the `Environment.presentInAppBrowser` seam (`present`, here).
/// Not KontextKit's `InAppBrowserManager`: it reports neither the controller nor the viewer's "Done", and closes
/// the browser whenever a scene activates (a pull of Notification Center over the browser included).
@MainActor
final class InAppBrowser {
    /// The window of the ad the browser opens over; the key window's is used without one.
    private let window: () -> UIWindow?
    /// The browser this ad presented, until UIKit lets it go: still the ad's own while its dismissal after "Done"
    /// runs, so no cover rule takes it for another screen. Weak: one taken away without "Done" (the app dismissing
    /// everything) is gone with it.
    private(set) weak var controller: UIViewController?
    /// The viewer has not tapped "Done" on `controller` yet.
    private var isUp = false

    init(window: @escaping () -> UIWindow?) {
        self.window = window
    }

    /// The browser is up over the app: presented, no "Done" yet, and still held by UIKit.
    var isOpen: Bool { isUp && controller != nil }

    /// Presents `url` in the browser. `false` when nothing could present it now (no view controller on screen
    /// can present, or one is mid-transition); the caller opens the link another way.
    func open(_ url: URL) -> Bool {
        let presented = Environment.presentInAppBrowser(url, window() ?? Environment.keyWindow()) { [weak self] finished in
            guard let self, finished === controller else { return }
            isUp = false
        }
        guard let presented else { return false }
        controller = presented
        isUp = true
        return true
    }

    /// The production presentation: an `SFSafariViewController` over the top view controller of `window`,
    /// over full screen, so the ad's view stays in its window under it. `onFinish` runs at the viewer's "Done".
    static func present(_ url: URL, in window: UIWindow?, onFinish: @escaping @MainActor (UIViewController) -> Void) -> UIViewController? {
        guard let presenter = LinearAdViewController.topPresenter(in: window) else { return nil }
        let browser = SFSafariViewController(url: url)
        let delegate = FinishDelegate(onFinish: onFinish)
        browser.delegate = delegate
        // The controller holds its delegate weakly: the delegate lives as long as the browser.
        objc_setAssociatedObject(browser, &FinishDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        browser.modalPresentationStyle = .overFullScreen
        presenter.present(browser, animated: true)
        return browser
    }

    /// Hears the viewer's "Done".
    private final class FinishDelegate: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0
        let onFinish: @MainActor (UIViewController) -> Void

        init(onFinish: @escaping @MainActor (UIViewController) -> Void) {
            self.onFinish = onFinish
        }

        @MainActor
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish(controller)
        }
    }
}
