import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// An ad under the in-app browser of its own click: an overlay or pause ad is not ended by it, its clocks and its
/// viewability wait while it is up and go on after "Done"; a linear ad reads as covered, so its page pauses the
/// video and plays it on; the click fires once, and the browser adds no beacon of its own.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdInAppBrowserTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    /// Keeps every `VideoAds` a test created alive for the test's duration: the ad holds its owner weakly.
    private let owners = Owners()

    /// What the browser seams were asked, and the viewer's "Done" for the one they showed: closed at once, as
    /// KontextKit's manager does; its close handler once it is off screen, which the runner never reports.
    @MainActor
    final class Browser {
        let controller = UIViewController()
        private(set) var urls: [URL] = []
        private var isOpen = false

        /// Installs the seams; `present` puts the controller on screen where the runner can.
        init(present: ((UIViewController) -> Void)? = nil) {
            let controller = controller
            Environment.presentInAppBrowser = { [weak self] url, _, _ in
                self?.urls.append(url)
                self?.isOpen = true
                present?(controller)
                return controller
            }
            Environment.openInAppBrowser = { [weak self] in self?.isOpen == true ? controller : nil }
        }

        func tapDone() {
            isOpen = false
        }
    }

    /// A view controller that presents a linear ad, and dismisses it at once.
    final class Presenter: UIViewController {
        override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
            completion?()
        }
    }

    init() {
        harness.player.view.frame.origin.y = 120
        window.add(harness.player.view)
    }

    /// A loaded ad, owned by a new `VideoAds` (tracking the harness's player when `tracksContent`), with a recording
    /// delegate.
    private func makeAd(_ payload: [String: Any], tracksContent: Bool = false) async throws -> (VideoAd, RecordingDelegate) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        if tracksContent { ads.track(harness.player) }
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        send(ad, "ad.loaded")
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        return (ad, delegate)
    }

    private func send(_ ad: VideoAd, _ type: String, _ extra: [String: Any] = [:]) {
        var body: [String: Any] = ["adId": ad.id, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        ad.bridge.receive(body, from: sender)
    }

    private func click(_ ad: VideoAd, _ url: String = "https://brand.test/offer") {
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": url])
    }

    /// The exposures the page heard, and every other message type the SDK sent it.
    private func recordPage(_ ad: VideoAd) -> (exposures: () -> [Double], types: () -> [String]) {
        var exposures: [Double] = []
        var types: [String] = []
        ad.bridge.onSend = { type, payload in
            types.append(type)
            if type == "ad.exposure", let value = payload["exposedPercentage"] as? Double { exposures.append(value) }
        }
        return ({ exposures }, { types })
    }

    /// `ticks` meter ticks, 0.1 s apart on the ad clock.
    private func tick(_ ad: VideoAd, _ ticks: Int) {
        for _ in 0..<ticks {
            advanceClock(by: 0.1)
            ad.meter?.tick()
        }
    }

    private func beacons() async -> [String] {
        await beaconsSettled()
        return harness.server.beacons.map(\.event)
    }

    // MARK: Inline

    /// The browser presented over the player's controller is the ad's own click, not another screen of the app:
    /// the overlay or pause ad under it stays up, and so after "Done".
    @Test func anInlineAdIsNotEndedByItsOwnClicksBrowser() async throws {
        for payload in [Fixtures.overlayAd(id: "o-browser"), Fixtures.ad(id: "p-browser")] {
            // A window each: the runner never finishes a dismissal.
            let screen = TestWindow()
            defer { screen.tearDown() }
            let player = UIView(frame: CGRect(x: 0, y: 120, width: 390, height: 300))
            screen.add(player)
            let browser = Browser { screen.root.present($0, animated: false) }
            let (ad, delegate) = try await makeAd(payload)
            try ad.show(in: player)
            click(ad)
            #expect(browser.urls.map(\.absoluteString) == ["https://brand.test/offer"], "in the in-app browser")
            if await waitUntil(2, { screen.root.presentedViewController === browser.controller }) {
                #expect(InlineScreen.coveringPresentation(over: player) === browser.controller, "a cover, were it not the ad's own")
                #expect(InlineScreen.coveringPresentation(over: player, except: ad.inAppBrowser.controller) == nil)
            }
            await sleepMs(Int(ViewabilityMeter.interval * 1000) * 4)
            #expect(!ad.hasEnded && delegate.endReasons.isEmpty, "\(ad.format): up under its own browser")
            browser.tapDone()
            #expect(!ad.inAppBrowser.isOpen)
            await sleepMs(Int(ViewabilityMeter.interval * 1000) * 2)
            #expect(!ad.hasEnded, "\(ad.format): and after Done")
            ad.dismiss()
        }
    }

    @Test func anInlineAdsClocksAndViewabilityWaitUnderTheBrowserAndGoOnAfterDone() async throws {
        let browser = Browser()
        let (ad, delegate) = try await makeAd(Fixtures.overlayAd(id: "o-browser-clock", duration: 2000))
        let page = recordPage(ad)
        try ad.show(in: harness.player.view)
        click(ad)
        let clock = try #require(ad.onScreenClock)
        #expect(await waitUntil { !clock.isCounting }, "the on-screen clock froze")
        #expect(page.exposures().last == 0, "not seen: exposure 0, \(page.exposures())")
        let frozenAt = clock.elapsed
        // Three seconds under the browser: past the off-screen grace and the 1 s an image needs to be viewable.
        tick(ad, 30)
        await sleepMs(100)
        #expect(clock.elapsed == frozenAt && !clock.isCounting, "no time on screen counted")
        #expect(ad.meter?.verdict == nil, "not viewable while covered")
        #expect(!ad.hasEnded && delegate.endReasons.isEmpty, "not out of sight, not ended")
        // Done: seen again, counting again, and viewable after its second.
        browser.tapDone()
        tick(ad, 1)
        #expect(clock.isCounting && (page.exposures().last ?? 0) > 0, "on screen again: \(page.exposures())")
        tick(ad, 12)
        #expect(ad.meter?.verdict == .viewable)
        #expect(page.types().filter { $0 == "ad.hide" || $0 == "ad.show" }.count == 1, "the show only: the browser is no hide")
        ad.dismiss()
    }

    /// A pause of the tracked content while the browser is up freezes the overlay, as one in the background does;
    /// the content playing again after Done lets it go on.
    @Test func aContentPauseUnderTheBrowserFreezesTheOverlay() async throws {
        VideoAd.contentResumeGrace = 0.1
        defer { VideoAd.contentResumeGrace = 1 }
        let browser = Browser()
        let (ad, delegate) = try await makeAd(Fixtures.overlayAd(id: "o-browser-pause", duration: 5000), tracksContent: true)
        try ad.show(in: harness.player.view)
        click(ad)
        harness.player.isPlaying = false   // the app paused its player under the browser
        ad.contentDidChange(.playingChanged(isPlaying: false))
        #expect(!ad.hasEnded && ad.wasContentPausedWhileInactive, "frozen, not ended")
        browser.tapDone()
        harness.player.isPlaying = true
        ad.contentDidChange(.tick)
        #expect(!ad.wasContentPausedWhileInactive)
        await sleepMs(250)   // past the grace
        #expect(!ad.hasEnded && delegate.endReasons.isEmpty, "it goes on")
        ad.dismiss()
    }

    /// Another ad's show (a pause ad, say) while the content is paused under the overlay's browser keeps the frozen
    /// overlay and is refused, as on Android; after Done, the content playing again lets the overlay go on.
    @Test func anotherAdsShowUnderTheBrowserKeepsTheFrozenOverlay() async throws {
        VideoAd.contentResumeGrace = 0.1
        defer { VideoAd.contentResumeGrace = 1 }
        let browser = Browser()
        let (ad, delegate) = try await makeAd(Fixtures.overlayAd(id: "o-browser-other", duration: 5000), tracksContent: true)
        let (pauseAd, _) = try await makeAd(Fixtures.ad(id: "p-browser-other"))
        try ad.show(in: harness.player.view)
        click(ad)
        harness.player.isPlaying = false
        ad.contentDidChange(.playingChanged(isPlaying: false))
        #expect(throws: VideoAdError.anotherAdShowing) { try pauseAd.show(in: harness.player.view) }
        #expect(!ad.hasEnded && ad.wasContentPausedWhileInactive, "the overlay stays, frozen")
        #expect(KontextVideo.shared.adOnScreen === ad)
        browser.tapDone()
        harness.player.isPlaying = true
        ad.contentDidChange(.tick)
        await sleepMs(250)   // past the grace
        #expect(!ad.hasEnded && delegate.endReasons.isEmpty, "it goes on")
        ad.dismiss()
    }

    @Test func aClickInTheBrowserFiresClickOnceAndTellsTheDelegateOnce() async throws {
        let browser = Browser()
        let (ad, delegate) = try await makeAd(Fixtures.ad(id: "p-browser-once"))
        try ad.show(in: harness.player.view)
        click(ad)
        #expect(browser.urls.count == 1 && delegate.clicks.count == 1)
        #expect(await harness.beaconArrives("click"))
        let fired = await beacons()
        #expect(fired.filter { $0 == "click" }.count == 1, "\(fired)")
        ad.dismiss()
    }

    @Test func theAdChoicesLinkOpensInTheBrowserToo() async throws {
        let browser = Browser()
        let (ad, delegate) = try await makeAd(Fixtures.ad(id: "p-browser-adchoices"))
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"])
        #expect(browser.urls.map(\.absoluteString) == ["https://adchoices.test"] && ad.inAppBrowser.isOpen)
        #expect(delegate.clicks.isEmpty)
        ad.dismiss()
    }

    // MARK: Linear

    /// Under the browser a linear ad reads as covered: the page hears exposure 0, on which it pauses its video, and
    /// an exposure again after Done, on which it plays on. No hide, no end, no beacon of the SDK's own.
    @Test func aLinearAdPausesUnderTheBrowserAndPlaysOnAfterDone() async throws {
        let browser = Browser()   // the runner refuses a presentation over the ad's controller: not presented
        let presenter = Presenter()
        let (ad, delegate) = try await makeAd(Fixtures.linearAd(id: "i-browser"))
        let page = recordPage(ad)
        let presented = UIWindow(windowScene: try #require(window.window.windowScene))
        presented.frame = window.window.frame
        presented.rootViewController = presenter
        presented.makeKeyAndVisible()
        defer { presented.isHidden = true; presented.rootViewController = nil }
        try ad.show(from: presenter)
        let controller = try #require(ad.linearController)
        #expect(await waitUntil { presenter.presentedViewController === controller })
        presented.addSubview(controller.view)
        ad.reachedScreen()
        send(ad, "video.start", ["playhead": 0])
        #expect(await waitUntil { (page.exposures().last ?? 0) > 50 }, "on screen: \(page.exposures())")
        click(ad)
        #expect(browser.urls.count == 1)
        tick(ad, 30)
        #expect(page.exposures().last == 0, "covered: the page pauses its video, \(page.exposures())")
        #expect(ad.meter?.verdict == nil, "not viewable while covered")
        #expect(!ad.hasEnded && delegate.endReasons.isEmpty)
        browser.tapDone()
        tick(ad, 1)
        #expect((page.exposures().last ?? 0) > 50, "exposed again: the page plays on, \(page.exposures())")
        tick(ad, 25)
        #expect(ad.meter?.verdict == .viewable)
        #expect(!page.types().contains("ad.hide"), "a hide is the end: the browser is not one")
        let fired = await beacons()
        #expect(fired.filter { $0 == "click" }.count == 1 && !fired.contains("pause") && !fired.contains("resume"),
                "the click once; pause and resume only as the page reports them: \(fired)")
        send(ad, "video.skip", ["playhead": 3000])
        #expect(await waitUntil { delegate.endReasons == [.skipped] })
    }
}
}
