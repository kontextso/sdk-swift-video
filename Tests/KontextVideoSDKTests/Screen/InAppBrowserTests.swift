import Foundation
import KontextKit
@testable import KontextVideoSDK
import SafariServices
import Testing
import UIKit

/// The in-app browser of an ad's click: open while its controller is the one KontextKit's manager has open, closed
/// at "Done", never open when nothing could present it; and the production presentation through the manager, over
/// the top view controller of the ad's window.
extension SerialSuites {
@Suite
@MainActor
struct InAppBrowserTests {
    private let harness = SDKHarness()

    @Test func openWhileItsControllerIsTheOneOpenAndClosedAtDone() {
        let window = TestWindow()
        defer { window.tearDown() }
        var presentedIn: UIWindow?
        let shown = UIViewController()
        var open: UIViewController? = shown
        Environment.presentInAppBrowser = { _, window, _ in presentedIn = window; return shown }
        Environment.openInAppBrowser = { open }
        let browser = InAppBrowser { window.window }
        #expect(browser.open(URL(string: "https://brand.test")!))
        #expect(browser.isOpen && browser.controller === shown && presentedIn === window.window, "over the ad's window")
        open = UIViewController()
        #expect(!browser.isOpen, "another browser open is not this one")
        open = nil   // Done: the manager closed it, and UIKit dismisses it
        #expect(!browser.isOpen && browser.controller === shown, "closed, and still its own while UIKit dismisses it")
    }

    @Test func aBrowserTakenAwayWithoutDoneIsNoLongerOpen() {
        var shown: UIViewController? = UIViewController()
        Environment.presentInAppBrowser = { _, _, _ in shown }
        Environment.openInAppBrowser = { nil }
        let browser = InAppBrowser { nil }
        #expect(browser.open(URL(string: "https://brand.test")!))
        shown = nil   // UIKit let go of it: the app dismissed everything
        #expect(browser.controller == nil && !browser.isOpen)
    }

    @Test func neverOpenWhenNothingCouldPresentIt() {
        Environment.presentInAppBrowser = { _, _, _ in nil }
        Environment.openInAppBrowser = { UIViewController() }
        let browser = InAppBrowser { nil }
        #expect(!browser.open(URL(string: "https://brand.test")!))
        #expect(!browser.isOpen)
    }

    /// Whether the runner finishes the presentation differs by OS: what the SDK asked the manager for is checked.
    @Test func theProductionPresentationIsTheManagersBrowserOverTheAdsWindow() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        Environment.reset()
        #expect(Environment.presentInAppBrowser(URL(string: "https://brand.test")!, nil) {} == nil,
                "no window, nothing presents")
        var closed = false
        let presented = try #require(Environment.presentInAppBrowser(URL(string: "https://brand.test")!, window.window) { closed = true })
        let manager = InAppBrowserManager.shared
        let safari = try #require(presented as? SFSafariViewController)
        #expect(presented === manager.presentedController && Environment.openInAppBrowser() === presented)
        #expect(safari.presentingViewController === window.root && safari.modalPresentationStyle == .overFullScreen,
                "full screen over the ad's window: the ad's view stays in it under the browser")
        #expect(manager.dismiss())
        #expect(Environment.openInAppBrowser() == nil, "closed at once")
        #expect(await waitUntil(3) { closed }, "the close handler once it is off screen")
    }
}
}
