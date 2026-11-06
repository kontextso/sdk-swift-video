import Foundation
@testable import KontextVideoSDK
import SafariServices
import Testing
import UIKit

/// The in-app browser of an ad's click: open while its controller is up, closed at the viewer's "Done" for that
/// controller only, never open when nothing could present it; and the production presentation over the top view
/// controller of the ad's window, full screen over it.
extension SerialSuites {
@Suite
@MainActor
struct InAppBrowserTests {
    private let harness = SDKHarness()

    @Test func openUntilTheViewerTapsDoneOnItsOwnController() throws {
        let window = TestWindow()
        defer { window.tearDown() }
        var finish: (@MainActor (UIViewController) -> Void)?
        var presentedIn: UIWindow?
        let shown = UIViewController()
        Environment.presentInAppBrowser = { _, window, onFinish in presentedIn = window; finish = onFinish; return shown }
        let browser = InAppBrowser { window.window }
        #expect(browser.open(URL(string: "https://brand.test")!))
        #expect(browser.isOpen && browser.controller === shown && presentedIn === window.window, "over the ad's window")
        let tapDone = try #require(finish)
        tapDone(UIViewController())
        #expect(browser.isOpen, "another browser's Done is not this one's")
        tapDone(shown)
        #expect(!browser.isOpen && browser.controller === shown, "closed, and still its own while UIKit dismisses it")
    }

    @Test func neverOpenWhenNothingCouldPresentIt() {
        Environment.presentInAppBrowser = { _, _, _ in nil }
        let browser = InAppBrowser { nil }
        #expect(!browser.open(URL(string: "https://brand.test")!))
        #expect(!browser.isOpen)
    }

    @Test func aBrowserTakenAwayWithoutDoneIsNoLongerOpen() {
        var shown: UIViewController? = UIViewController()
        Environment.presentInAppBrowser = { _, _, _ in shown }
        let browser = InAppBrowser { nil }
        #expect(browser.open(URL(string: "https://brand.test")!))
        shown = nil   // UIKit let go of it: the app dismissed everything
        #expect(!browser.isOpen)
    }

    /// Whether the runner finishes the presentation differs by OS: what the SDK built and asked for is checked.
    @Test func theProductionPresentationIsASafariControllerFullScreenOverTheAdsWindow() throws {
        let window = TestWindow()
        defer { window.tearDown() }
        var finished: UIViewController?
        let presented = try #require(InAppBrowser.present(URL(string: "https://brand.test")!, in: window.window) { finished = $0 })
        let safari = try #require(presented as? SFSafariViewController)
        #expect(safari.modalPresentationStyle == .overFullScreen, "the ad's view stays in its window under it")
        safari.delegate?.safariViewControllerDidFinish?(safari)
        #expect(finished === safari, "Done reaches the owner")
        #expect(InAppBrowser.present(URL(string: "https://brand.test")!, in: nil) { _ in } == nil, "no window, nothing presents")
    }
}
}
