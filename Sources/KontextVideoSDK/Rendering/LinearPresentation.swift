import UIKit

/// A linear ad's controller going on and off screen through UIKit, each with a watchdog: UIKit can refuse a
/// presentation, or never finish a dismissal, without an error, and its completion then never runs. The ad
/// decides what each outcome means; this only says which one came.
@MainActor
enum LinearPresentation {
    /// Presents `controller` from `presenter`. `onPresented` runs when UIKit confirms it, or when the watchdog
    /// finds the controller on screen without that confirmation; `onFailed` when it never got there. The
    /// watchdog stops once `isPending` turns false (the ad ended, or was presented). After `timeout`, a
    /// controller that never reached a window failed; one that did, without the completion, is taken as
    /// presented after five times that.
    static func present(_ controller: LinearViewController, from presenter: UIViewController, adId: String, timeout: TimeInterval,
                        isPending: @escaping @MainActor () -> Bool, onPresented: @escaping @MainActor () -> Void,
                        onFailed: @escaping @MainActor () -> Void) {
        presenter.present(controller, animated: true) {
            onPresented()
        }
        Task {
            let step = min(timeout, 0.25)
            let deadline = Environment.now() + timeout
            let cap = Environment.now() + timeout * 5
            while isPending(), Environment.now() < cap {
                if Environment.now() >= deadline, controller.view.window == nil { break }
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            }
            guard isPending() else { return }
            // Taken as presented only on evidence the viewer can see it: a visible window, an active app.
            if let window = controller.view.window, !window.isHidden, window.alpha > AdPlacement.transparent, Environment.isWindowActive(window) {
                Logger.warning("ad \(adId.prefix(8)): UIKit never confirmed the presentation, but the controller is on screen; taken as presented")
                onPresented()
            } else {
                Logger.error("ad \(adId.prefix(8)): UIKit did not present the linear ad; ended as failed")
                onFailed()
            }
        }
    }

    /// Dismisses `controller` from its presenter, which takes the ad and anything over it (an install click's
    /// store sheet). Returns `false`, with nothing dismissed, when UIKit no longer presents it. `completion`
    /// runs when the dismissal finished; if UIKit never says so, and `isPending` is still true, once the
    /// controller has left the screen after `timeout`, or after five times that while it still has not
    /// (`timedOut`: reported over a controller UIKit did not take down).
    static func dismiss(_ controller: LinearViewController, timeout: TimeInterval, isPending: @escaping @MainActor () -> Bool,
                        completion: @escaping @MainActor (_ timedOut: Bool) -> Void) -> Bool {
        // The ad ends it: its disappearance is no interruption.
        controller.isEndingByAd = true
        guard controller.isPresentedLive, let presenter = controller.presentingViewController else { return false }
        presenter.dismiss(animated: true) { completion(false) }
        Task {
            let deadline = Environment.now() + timeout
            let cap = Environment.now() + timeout * 5
            repeat {
                try? await Task.sleep(nanoseconds: UInt64(min(timeout, 0.25) * 1_000_000_000))
            } while Environment.now() < deadline || (controller.view.window != nil && Environment.now() < cap)
            guard isPending() else { return }
            completion(controller.view.window != nil)
        }
        return true
    }
}
