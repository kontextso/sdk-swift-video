@testable import KontextVideoSDK
import Testing
import UIKit
import WebKit

/// The full-screen container: its one decision (interruption or the ad's own ending) and its setup.
@MainActor
struct LinearViewControllerTests {
    private func makeController() -> (LinearViewController, () -> Int) {
        let controller = LinearViewController(webView: WKWebView(frame: .zero))
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

    @Test func aCoveredViewIsNotAnInterruption() {
        let (controller, interruptions) = makeController()
        controller.viewDisappeared(isBeingDismissed: false, isMovingFromParent: false, hasPresenter: true)
        #expect(interruptions() == 0, "another controller presented over the ad does not end it")
    }

    @Test func theAdsOwnDismissalIsNotAnInterruption() {
        let (controller, interruptions) = makeController()
        controller.isEndingByAd = true
        controller.viewDisappeared(isBeingDismissed: true, isMovingFromParent: false, hasPresenter: true)
        #expect(interruptions() == 0)
    }

    @Test func presentsFullScreenWithTheWebViewFillingIt() {
        let webView = WKWebView(frame: .zero)
        let controller = LinearViewController(webView: webView)
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
