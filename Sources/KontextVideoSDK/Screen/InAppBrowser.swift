import UIKit

/// The in-app browser one ad's click opened over the app (KontextKit's `InAppBrowserManager`), and whether it is
/// still open.
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
/// `controller`. The manager calls are the `Environment.presentInAppBrowser` and `openInAppBrowser` seams.
@MainActor
final class InAppBrowser {
    /// The window of the ad the browser opens over; the key window's is used without one.
    private let window: () -> UIWindow?
    /// The browser this ad presented, until UIKit lets it go: still the ad's own while its dismissal after "Done"
    /// runs, so no cover rule takes it for another screen. Weak: one taken away without "Done" (the app dismissing
    /// everything) is gone with it.
    private(set) weak var controller: UIViewController?

    init(window: @escaping () -> UIWindow?) {
        self.window = window
    }

    /// This ad's browser is the one open over the app: presented, and not closed since.
    var isOpen: Bool {
        guard let controller else { return false }
        return Environment.openInAppBrowser() === controller
    }

    /// Presents `url` in the browser. `false` when it cannot appear now (nothing on screen can present it, or a
    /// browser is already open or still leaving the screen); the caller opens the link another way.
    func open(_ url: URL) -> Bool {
        let presented = Environment.presentInAppBrowser(url, window() ?? Environment.keyWindow()) {
            // Closed and off screen. The clocks and a linear video went on at "Done" already: `isOpen` is false
            // from then on.
            Logger.info("the in-app browser closed; the ad goes on")
        }
        guard let presented else { return false }
        controller = presented
        return true
    }
}
