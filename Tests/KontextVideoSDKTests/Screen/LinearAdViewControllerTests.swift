@testable import KontextVideoSDK
import Testing
import UIKit
import WebKit

/// The full-screen container: its one decision (interruption or the ad's own ending) and its setup. Serial
/// although it touches no shared state: it creates WebViews, and each launches a web content process, which in
/// parallel with the serial suites competed with their real page loads.
extension SerialSuites {
@Suite
@MainActor
struct LinearViewControllerTests {
    private func makeController() -> (LinearAdViewController, () -> Int) {
        let controller = LinearAdViewController(webView: WKWebView(frame: .zero))
        var interruptions = 0
        controller.onInterrupted = { interruptions += 1 }
        return (controller, { interruptions })
    }

    @Test func removalTheAdDidNotAskForIsAnInterruption() {
        let (controller, interruptions) = makeController()
        controller.viewDisappeared(isBeingDismissed: true, isMovingFromParent: false, hasPresenter: true)
        controller.viewDisappeared(isBeingDismissed: false, isMovingFromParent: true, hasPresenter: true)
        controller.viewDisappeared(isBeingDismissed: false, isMovingFromParent: false, hasPresenter: false)
        #expect(interruptions() == 3)
    }

    /// A presenter that allows landscape only, as a landscape player screen does.
    final class LandscapeOnly: UIViewController {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    }

    @Test func theAdFollowsThePresentersOrientations() async throws {
        let (controller, _) = makeController()
        #expect(controller.supportedInterfaceOrientations == .all, "not presented yet")
        let window = TestWindow()
        defer { window.tearDown() }
        let presenter = LandscapeOnly()
        window.window.rootViewController = presenter
        LinearPresentation.present(controller, from: presenter, adId: "orientation", timeout: 1, isPending: { false },
                                   onPresented: {}, onFailed: {})
        #expect(await waitUntil { controller.presentingViewController === presenter })
        #expect(controller.supportedInterfaceOrientations == .landscape)
    }

    /// A presenter that lets the controller it presents decide, as apps do so full-screen media can rotate.
    final class ForwardingPresenter: UIViewController {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            presentedViewController?.supportedInterfaceOrientations ?? .landscape
        }
    }

    @Test func aPresenterThatAsksThePresentedControllerDoesNotLoop() async throws {
        let (controller, _) = makeController()
        let window = TestWindow()
        defer { window.tearDown() }
        let presenter = ForwardingPresenter()
        window.window.rootViewController = presenter
        LinearPresentation.present(controller, from: presenter, adId: "orientation", timeout: 1, isPending: { false },
                                   onPresented: {}, onFailed: {})
        #expect(await waitUntil { controller.presentingViewController === presenter })
        // Asking the presenter now would ask the ad again, without end: the mask is the one taken at presentation.
        #expect(controller.supportedInterfaceOrientations == .landscape)
        #expect(presenter.supportedInterfaceOrientations == .landscape)
    }

    @Test func aCoveredViewIsNotAnInterruption() {
        let (controller, interruptions) = makeController()
        controller.viewDisappeared(isBeingDismissed: false, isMovingFromParent: false, hasPresenter: true)
        #expect(interruptions() == 0, "another controller presented over the ad does not end it")
    }

    @Test func theAdsOwnDismissalIsNotAnInterruption() {
        let (controller, interruptions) = makeController()
        controller.isEndingByAd = true
        controller.viewDisappeared(isBeingDismissed: true, isMovingFromParent: false, hasPresenter: true)
        controller.viewDisappeared(isBeingDismissed: false, isMovingFromParent: false, hasPresenter: false)
        controller.viewDisappeared(isBeingDismissed: false, isMovingFromParent: true, hasPresenter: true)
        #expect(interruptions() == 0, "whatever UIKit reports while the ad ends itself")
    }

    @Test func uiKitsDisappearanceCallbackReachesTheDecision() {
        // The real `viewDidDisappear`, through UIKit's appearance transition: a controller with no presenter
        // that disappears is an interruption. Deleting the override makes this fail.
        let (controller, interruptions) = makeController()
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        #expect(interruptions() == 1)
        controller.isEndingByAd = true
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        #expect(interruptions() == 1, "not while the ad ends itself")
    }

    @Test func presentsFullScreenWithTheWebViewFillingIt() {
        let webView = WKWebView(frame: .zero)
        let controller = LinearAdViewController(webView: webView)
        #expect(controller.modalPresentationStyle == .fullScreen)
        #expect(controller.modalTransitionStyle == .crossDissolve)
        controller.view.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        controller.loadViewIfNeeded()
        #expect(controller.view.subviews.first === webView)
        #expect(webView.frame == controller.view.bounds)
        #expect(controller.view.backgroundColor == .black)
        #expect(controller.prefersStatusBarHidden)
        #expect(controller.prefersHomeIndicatorAutoHidden)
        #expect(controller.view.accessibilityViewIsModal, "VoiceOver reads the ad alone")
    }
}
}
