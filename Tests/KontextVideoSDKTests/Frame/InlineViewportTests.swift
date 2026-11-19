import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// An inline ad's page reads the view the SDK placed it in, from its first moment on screen: its viewport is
/// that view and `env(safe-area-inset-*)` is 0, as on Android. The page loads parked in the key window at the
/// window's size, where it reads the whole window and its safe area; WebKit passes a new frame and safe area to
/// the page only at the next commit, so without one at attach the page was told `ad.show` (and laid out its
/// controls) in the parked viewport, shifted under the notch.
extension SerialSuites {
@Suite
@MainActor
struct InlineViewportTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()
    /// The size of the screen, so the window has the device's safe area (the notch or island, the home indicator).
    private let window = TestWindow(size: UIScreen.main.bounds.size)

    init() {
        pages.install()
        // Parked in the window the ad is shown in, at its full size and safe area, as in an app.
        Environment.parkingWindow = { [window] in window.window }
        harness.player.view.frame = window.root.view.bounds
        window.add(harness.player.view)
    }

    /// The viewport's size and the page's top and bottom safe-area insets, as the page reads them.
    private static let probe = """
        (function () { var e = document.createElement('div');
        e.style.cssText = 'position:fixed;top:0;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)';
        document.body.appendChild(e); var s = getComputedStyle(e); var r = [innerWidth, innerHeight, s.paddingTop, s.paddingBottom].join(' ');
        e.remove(); return r; })()
        """

    @Test(arguments: ["fullscreen", "top"])
    func thePageReadsItsViewWithNoInsetsAtShow(position: String) async throws {
        let safeArea = window.root.view.safeAreaInsets
        try #require(safeArea.top > 0, "the test window has the device's safe area")
        _ = await KontextVideo.shared.initialize(with: harness.configuration)
        let ads = harness.player.ads(for: .init(id: "100001-6", language: "en", title: "Episode 6", duration: 92))
        let id = "img-viewport-\(position)"
        let format: AdFormat = position == "fullscreen" ? .pauseFullscreen : .pause
        harness.serve(Fixtures.ad(id: id, format: format.rawValue, position: position, size: format == .pause ? ["width": 300, "height": 300] : nil,
                                  frameURL: "\(Fixtures.frameOrigin)/frame/\(id)?cover=1"))
        let ad = try await ads.format(format)
        try await ad.load()

        try ad.show(in: harness.player.view)
        defer { ad.dismiss() }
        let view = try #require(adFrame(in: harness.player.view))
        #expect(view.minY >= safeArea.top, "placed inside the safe area")
        let expected = "\(Int(view.width)) \(Int(view.height)) 0px 0px"
        // At once, as the page's own `ad.show` handler would read it.
        var shown = try await ad.bridge.webView.evaluateJavaScript(Self.probe) as? String
        if #unavailable(iOS 17) {
            // Older WebKit applies a view's new frame to the page asynchronously, so give it up to 1 s there.
            let deadline = Date().addingTimeInterval(1)
            while shown != expected, Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
                shown = try await ad.bridge.webView.evaluateJavaScript(Self.probe) as? String
            }
        }
        #expect(shown == expected, "the view \(view)")
    }
}
}
