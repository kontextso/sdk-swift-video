import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// Whole flows through the public API with everything real but the network: a genuine WKWebView
/// loading a page served in-process that speaks the frame protocol, the scripted ad server behind
/// URLSession, beacons recorded as they arrive. What the example app does, asserted.
extension SerialSuites {
@Suite
@MainActor
struct IntegrationTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()
    private let window = TestWindow()

    init() {
        pages.install()
        window.add(harness.player.view)
    }

    private func start() async -> VideoAds {
        _ = await KontextVideo.shared.initialize(with: harness.configuration)
        return harness.player.ads(for: .init(id: "100001-6", language: "en", title: "Episode 6", duration: 92))
    }

    /// Runs JavaScript in the ad's page, as the viewer's actions would.
    private func inPage(_ ad: VideoAd, _ script: String) async {
        _ = try? await ad.bridge.webView.evaluateJavaScript(script)
    }

    private func events(for adId: String) -> [String] {
        harness.server.beacons.filter { $0.adId == adId }.map { beacon in beacon.query["part"].map { "\(beacon.event)(\($0))" } ?? beacon.event }
    }

    // MARK: Pause ad, image creative

    @Test func pauseAdFromLoadToDismiss() async throws {
        let ads = await start()
        harness.player.playhead = 3.25
        harness.serve(Fixtures.ad(id: "img-pause"))
        let delegate = RecordingDelegate()

        let ad = try await ads.format(.pause, options: PauseOptions(positions: [.top, .bottom])).load()
        ad.delegate = delegate
        #expect(ad.isReady)
        #expect(await waitUntil { self.events(for: "img-pause") == ["loaded"] })

        try ad.show(in: harness.player.view)
        #expect(delegate.events == ["impression"])
        #expect(harness.player.view.subviews.count == 1)
        #expect(await waitUntil { Set(self.events(for: "img-pause")).isSuperset(of: ["creativeView", "iconView", "impression"]) })
        #expect(await waitUntil(2) { self.events(for: "img-pause").contains("viewable") }, "50 % for 1 s")
        let impression = harness.server.beacons.first { $0.adId == "img-pause" && $0.event == "impression" }
        #expect(impression?.query["cph"] == "00:00:03.250", "the content playhead at the impression")
        let exposure = try await ad.bridge.webView.evaluateJavaScript("window.lastExposure") as? Double
        #expect(exposure == 1, "the page heard ad.exposure")

        ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
        #expect(harness.player.view.subviews.isEmpty)
        #expect(await waitUntil { self.events(for: "img-pause").contains("overlayViewDuration") })
        #expect(!events(for: "img-pause").contains("close"))
        #expect(events(for: "img-pause").filter { $0 == "impression" }.count == 1)
    }

    @Test func pauseAdClosedByTheViewer() async throws {
        let ads = await start()
        harness.serve(Fixtures.ad(id: "img-close"))
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.pause).load()
        ad.delegate = delegate
        try ad.show(in: harness.player.view)
        await inPage(ad, "window.close('close')")
        #expect(await waitUntil { delegate.endReasons == [.closed] })
        #expect(await waitUntil { self.events(for: "img-close").contains("close") })
    }

    @Test func clickOpensTheURLOnlyAfterATouch() async throws {
        let ads = await start()
        harness.serve(Fixtures.ad(id: "img-click"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.pause).load()
        ad.delegate = delegate
        try ad.show(in: harness.player.view)
        await inPage(ad, "window.click('https://brand.test/offer', 'creative')")
        await sleepMs(100)
        #expect(opened.isEmpty, "a click the viewer did not make is a forced redirect")
        ad.bridge.noteTouch()
        await inPage(ad, "window.click('https://brand.test/offer', 'creative')")
        #expect(await waitUntil { opened.count == 1 })
        #expect(delegate.clicks.first?.url.absoluteString == "https://brand.test/offer")
        #expect(await waitUntil { self.events(for: "img-click").contains("click") })
        ad.dismiss()
    }

    @Test func aPageNavigatingAwayIsAClickOnlyAfterATouchAndNeverLeavesTheWebView() async throws {
        let ads = await start()
        harness.serve(Fixtures.ad(id: "img-nav"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.pause).load()
        ad.delegate = delegate
        try ad.show(in: harness.player.view)
        // A forced redirect: no touch, so the navigation is cancelled and nothing opens.
        await inPage(ad, "window.location.href = 'https://brand.test/forced'")
        await sleepMs(200)
        #expect(opened.isEmpty)
        #expect(ad.bridge.webView.url?.scheme == FramePageServer.scheme, "the page stayed")
        // The same navigation right after a touch is a click the page could not report.
        ad.bridge.noteTouch()
        await inPage(ad, "window.location.href = 'https://brand.test/tap'")
        #expect(await waitUntil { opened.count == 1 })
        #expect(opened.first?.absoluteString == "https://brand.test/tap")
        #expect(delegate.clicks.first?.area == "creative")
        #expect(ad.bridge.webView.url?.scheme == FramePageServer.scheme, "still our page, the URL opened outside")
        ad.dismiss()
    }

    // MARK: Linear, video creative

    @Test func linearPlaysToCompletionWithTheReward() async throws {
        let ads = await start()
        harness.serve(Fixtures.linearAd(id: "vid-full", reward: ["label": "coins", "amount": 50]))
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.linear, options: LinearOptions(rewarded: true)).load()
        ad.delegate = delegate
        #expect(ad.reward == VideoAd.Reward(label: "coins", amount: 50))

        try ad.show(from: window.root)
        #expect(delegate.events.isEmpty)
        #expect(await waitUntil(3) { delegate.events.contains("impression") }, "at video.start")
        #expect(await waitUntil(3) { delegate.rewards.count == 1 }, "at video.complete")
        #expect(delegate.endReasons.isEmpty, "the end card is up")
        #expect(await waitUntil { Set(self.events(for: "vid-full")).isSuperset(of: ["start", "firstQuartile", "midpoint", "progress", "thirdQuartile", "complete", "creativeView(endCard)"]) })
        let progress = harness.server.beacons.first { $0.adId == "vid-full" && $0.event == "progress" }
        #expect(progress?.query["offset"] == "5000")

        #expect(ad.isCompleted)
        await inPage(ad, "window.closeEndCard()")
        #expect(await waitUntil { delegate.endReasons == [.closed] }, "the end card's ✕ is .closed; isCompleted says the video was watched")
        #expect(await waitUntil { self.events(for: "vid-full").contains("close") })
        #expect(!events(for: "vid-full").contains("overlayViewDuration"), "linear ads have no view duration")
        #expect(!events(for: "vid-full").contains("skip"))
    }

    @Test func linearSkipped() async throws {
        let ads = await start()
        harness.serve(Fixtures.linearAd(id: "vid-skip"))
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.linear).load()
        ad.delegate = delegate
        try ad.show(from: window.root)
        #expect(await waitUntil(3) { delegate.events.contains("impression") })
        await inPage(ad, "window.skip(1500)")
        #expect(await waitUntil { delegate.endReasons == [.skipped] })
        #expect(await waitUntil { self.events(for: "vid-skip").contains("skip") })
        #expect(harness.server.beacons.first { $0.adId == "vid-skip" && $0.event == "skip" }?.query["aph"] == "00:00:01.500")
        #expect(!events(for: "vid-skip").contains("complete"))
    }

    @Test func linearThatFailsDuringPlayback() async throws {
        let ads = await start()
        harness.serve(Fixtures.linearAd(id: "vid-fail"))
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.linear).load()
        ad.delegate = delegate
        try ad.show(from: window.root)
        #expect(await waitUntil(3) { delegate.events.contains("impression") })
        await inPage(ad, "window.fail(405)")
        #expect(await waitUntil { delegate.endReasons == [.failed] })
        #expect(delegate.events.suffix(2) == ["fail", "end:failed"])
        #expect(await waitUntil { self.events(for: "vid-fail").contains("error") })
        #expect(harness.server.beacons.first { $0.adId == "vid-fail" && $0.event == "error" }?.query["code"] == "405")
    }

    // MARK: Invalidation and destruction

    @Test func targetingChangeDiscardsALoadedAdAndTheNextLoadCarriesTheNewValues() async throws {
        let ads = await start()
        harness.serve(Fixtures.ad(id: "img-t1"))
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.pause).load()
        ad.delegate = delegate
        KontextVideo.shared.user = KontextVideo.User(id: "u2")
        #expect(delegate.invalidations == [.targetingChanged])
        #expect(ad.isReady == false)
        harness.serve(Fixtures.ad(id: "img-t2"))
        let next = try await ads.format(.pause).load()
        #expect(next.id == "img-t2")
        #expect((harness.server.requests(to: "/v2/video/ads").last?.body?["user"] as? [String: Any])?["id"] as? String == "u2")
    }

    @Test func destroyWithAnAdOnScreenEndsItAndFreesEverything() async throws {
        let ads = await start()
        harness.serve(Fixtures.overlayAd(id: "img-ov"))
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.overlay).load()
        ad.delegate = delegate
        try ad.show(in: harness.player.view)
        ads.destroy()
        #expect(delegate.endReasons == [.destroyed])
        #expect(harness.player.view.subviews.isEmpty)
        #expect(await waitUntil { self.events(for: "img-ov").contains("overlayViewDuration") })
        do {
            _ = try await ads.format(.overlay).load()
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }

    @Test func expiredAdCannotBeShown() async throws {
        let ads = await start()
        harness.serve(Fixtures.ad(id: "img-exp", expires: 1500))  // enough for the page to load first
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.pause).load()
        ad.delegate = delegate
        #expect(ad.isReady)
        #expect(await waitUntil(3) { delegate.invalidations == [.expired] })
        do { try ad.show(in: harness.player.view) } catch VideoAdError.invalidated(.expired) {} catch { Issue.record("expected expired") }
        harness.serve(Fixtures.ad(id: "img-exp2"))
        _ = try await ads.format(.pause).load()
    }

    @Test func movingOnToTheNextEpisodeDestroysThePreviousAdsOnScreen() async throws {
        let ads = await start()
        harness.serve(Fixtures.overlayAd(id: "img-ep1"))
        let delegate = RecordingDelegate()
        let ad = try await ads.format(.overlay).load()
        ad.delegate = delegate
        try ad.show(in: harness.player.view)
        let next = harness.player.ads(for: .init(id: "100001-7", language: "en"))
        ads.destroy()
        #expect(delegate.endReasons == [.destroyed], "nothing of episode 6 sits over episode 7")
        #expect(harness.player.view.subviews.isEmpty)
        withExtendedLifetime(next) {}
    }

    @Test func prefetchForTheNextEpisodeUsesContentTimeZero() async throws {
        let current = await start()
        harness.player.playhead = 80
        // The next episode's VideoAds has no playhead source yet: the player's time belongs to episode 6.
        let next = VideoAds(content: .init(id: "100001-7", language: "en"), playerSize: harness.player.view.bounds.size)
        harness.serve(Fixtures.linearAd(id: "vid-next"))
        _ = try await next.format(.linear).load()
        let player = harness.server.requests(to: "/v2/video/ads").last?.body?["player"] as? [String: Any]
        #expect(player?["playhead"] as? Int == 0, "the player's 80 s belong to the current episode")
        #expect((harness.server.requests(to: "/v2/video/ads").last?.body?["video"] as? [String: Any])?["id"] as? String == "100001-7")
        withExtendedLifetime(current) {}
    }

    @Test func everyBridgeIsReleasedWhenItsAdIsGone() async throws {
        let ads = await start()
        harness.serve(Fixtures.ad(id: "img-rel"))
        weak var bridge: FrameBridge?
        try await {
            let ad = try await ads.format(.pause).load()
            bridge = ad.bridge
            #expect(bridge != nil)
        }()
        #expect(await waitUntil { bridge == nil }, "dropping the ad releases its WebView")
    }
}
}
