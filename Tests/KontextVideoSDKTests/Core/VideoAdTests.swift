import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// One ad's life: what it exposes, `show()` and `show(from:)`, `dismiss()`, every page event mapped to
/// the delegate and the beacons, and the one terminal `didEnd`. Pages are driven directly through the
/// bridge (`receive`) so each path is exact; real pages are the integration suite's job.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameBridge.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    /// Keeps every `VideoAds` a test created alive for the test's duration: the ad holds its owner weakly.
    private let owners = Owners()

    final class Owners {
        var all: [VideoAds] = []
        /// The ad holds its bid weakly; the test keeps it.
        var bids: [VideoAd.Bid] = []
    }

    init() {
        window.add(harness.player.view)
    }

    /// An ad in the loaded state, owned by a `VideoAds`, with a recording delegate.
    private func makeAd(_ payload: [String: Any], loaded: Bool = true) async throws -> (VideoAd, RecordingDelegate, VideoAds) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = makeLoose(payload, in: ads)
        if loaded {
            ad.bridge.receive(message("ad.loaded", adId: ad.id), from: sender)
        }
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        return (ad, delegate, ads)
    }

    /// An ad on its own bid, rendered outside the `load()` flow so each page event is driven by hand.
    private func makeLoose(_ payload: [String: Any], in ads: VideoAds) -> VideoAd {
        let bid = VideoAd.Bid(received: try! Fixtures.received(payload), owner: ads)
        owners.bids.append(bid)
        return VideoAd(bid: bid)
    }

    private func message(_ type: String, _ extra: [String: Any] = [:], adId: String) -> [String: Any] {
        var body: [String: Any] = ["adId": adId, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        return body
    }

    private func send(_ ad: VideoAd, _ type: String, _ extra: [String: Any] = [:]) {
        ad.bridge.receive(message(type, extra, adId: ad.id), from: sender)
    }

    private func beacons() async -> [String] {
        await sleepMs(80)
        return harness.server.beacons.map { beacon in beacon.query["part"].map { "\(beacon.event)(\($0))" } ?? beacon.event }
    }

    // MARK: What the ad exposes

    @Test func pauseAdExposesItsFacts() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p1", expires: 90_000))
        #expect(ad.id == "p1")
        #expect(ad.format == .pause)
        #expect(ad.price == VideoAd.Price(value: 7.5, currency: "USD", precision: .exact))
        #expect(ad.position == .top)
        #expect(ad.size == VideoAd.Size(width: 300, height: 300))
        #expect(ad.duration == nil)
        #expect(ad.skipOffset == nil)
        #expect(ad.received.lifetime == 90, "expires (ms from receipt) in seconds")
        #expect(ad.isReady)
        #expect(ad.wasShown == false)
    }

    @Test func overlayAdExposesSecondsAndATimedAnswerIsAnOrdinaryAd() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "o1", format: "overlay", trigger: ["kind": "window", "from": 4000, "to": 10_000], position: "bottom", duration: 6000))
        #expect(ad.format == .overlay)
        #expect(ad.position == .bottom)
        #expect(ad.duration == 6)
        #expect(ad.isReady, "no timed mode yet: the window on the wire changes nothing for the app")
    }

    @Test func linearAdExposesVideoFacts() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i1", duration: 15_000, skipOffset: 5000))
        #expect(ad.position == nil)
        #expect(ad.size == nil)
        #expect(ad.duration == 15)
        #expect(ad.skipOffset == 5)
        let (fullscreen, _, _) = try await makeAd(Fixtures.ad(id: "p2", position: "fullscreen", size: nil))
        #expect(fullscreen.position == .fullscreen)
        #expect(fullscreen.size == nil)
    }

    @Test func notLoadedAdIsNotReady() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p3"), loaded: false)
        #expect(ad.isReady == false)
        #expect(throws: VideoAdError.self) { try ad.show(in: harness.player.view) }
    }

    @Test func expiryIsFoundOutAtShowNotByATimer() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p4", expires: 30_000))
        #expect(ad.isReady)
        advanceClock(by: 31)
        #expect(ad.isReady == false)
        #expect(ad.invalidationReason == nil, "nothing happens until the next call")
        #expect(delegate.events.isEmpty)
        do {
            try ad.show(in: harness.player.view)
            Issue.record("expected a throw")
        } catch VideoAdError.invalidated(let reason) {
            #expect(reason == .expired)
        }
    }

    // MARK: show()

    @Test func showPlacesTheAdAtTheTopAndReportsShowAndImpression() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p5"))
        var sent: [String] = []
        ad.bridge.onSend = { type, _ in sent.append(type) }
        try ad.show(in: harness.player.view)
        #expect(ad.wasShown)
        #expect(ad.isReady == false, "shown at most once")
        #expect(delegate.events == ["impression"], "an image counts at show")
        #expect(sent.first == "ad.show")
        let host = try #require(harness.player.view.subviews.last)
        #expect(host.subviews.first === ad.bridge.webView)
        #expect(host.frame == CGRect(x: 85, y: 0, width: 220, height: 220), "300×300 scaled to the 220 pt height, centred")
        let fired = await beacons()
        #expect(Set(fired).isSuperset(of: ["creativeView", "iconView", "impression"]))
        #expect(!fired.contains("overlayViewDuration"))
    }

    @Test func anHtmlCreativeCountsItsImpressionAtShowLikeAnImage() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "h1", creative: "html"))
        try ad.show(in: harness.player.view)
        #expect(delegate.events == ["impression"], "no first frame to wait for")
        #expect(Set(await beacons()).isSuperset(of: ["creativeView", "impression"]))
    }

    @Test func showPlacesABottomOverlayAtTheBottom() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o2"))
        try ad.show(in: harness.player.view)
        let host = try #require(harness.player.view.subviews.last)
        #expect(host.frame == CGRect(x: 35, y: 130, width: 320, height: 90))
    }

    @Test func fullscreenPauseAdFillsThePlayer() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6", position: "fullscreen", size: nil))
        try ad.show(in: harness.player.view)
        let host = try #require(harness.player.view.subviews.last)
        #expect(host.frame == harness.player.view.bounds)
    }

    @Test func showThrowsContainerTooSmallBelowHalfTheSizeAndTheAdStaysReady() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p7", size: ["width": 600, "height": 600, "scalable": true, "maintainAspectRatio": true]))
        do {
            try ad.show(in: harness.player.view)
            Issue.record("expected a throw")
        } catch VideoAdError.containerTooSmall(let minimum) {
            #expect(minimum == CGSize(width: 300, height: 300))
        }
        #expect(ad.isReady, "the ad stays ready for a bigger view")
        #expect(ad.invalidationReason == nil)
        #expect(ad.wasShown == false)
        #expect(harness.player.view.subviews.isEmpty)
        #expect(await beacons() == ["loaded"], "nothing fired beyond the loaded that came before")
        let big = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.add(big)
        try ad.show(in: big)
        #expect(ad.wasShown)
    }

    @Test func showTwiceThrowsAlreadyShown() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p8"))
        try ad.show(in: harness.player.view)
        #expect(throws: VideoAdError.self) { try ad.show(in: harness.player.view) }
        do { try ad.show(in: harness.player.view) } catch VideoAdError.alreadyShown {} catch { Issue.record("expected alreadyShown") }
    }

    @Test func showInOnALinearAdThrowsWrongPresentation() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i2"))
        do { try ad.show(in: harness.player.view) } catch VideoAdError.wrongPresentation {} catch { Issue.record("expected wrongPresentation, got \(error)") }
        #expect(ad.isReady, "untouched")
    }

    @Test func showPlacesTheAdInTheViewItIsGiven() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p9"))
        let other = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.add(other)
        try ad.show(in: other)
        #expect(other.subviews.count == 1, "the SDK's host view went into the view passed to show(in:)")
        #expect(harness.player.view.subviews.isEmpty)
        try ad.dismiss()
        #expect(other.subviews.isEmpty, "and is removed at the end")
    }

    @Test func showWhileAnotherAdIsOnScreenAnywhereInTheAppThrowsAnotherAdShowing() async throws {
        let (overlay, _, _) = try await makeAd(Fixtures.overlayAd(id: "p9a"))
        try overlay.show(in: harness.player.view)
        let otherVideo = harness.player.ads(for: .init(id: "other", language: "en"))
        owners.all.append(otherVideo)
        let pause = makeLoose(Fixtures.ad(id: "p9b"), in: otherVideo)
        pause.bridge.receive(message("ad.loaded", adId: pause.id), from: sender)
        do { try pause.show(in: harness.player.view) } catch VideoAdError.anotherAdShowing {} catch { Issue.record("expected anotherAdShowing, got \(error)") }
        #expect(pause.isReady, "untouched")
        #expect(pause.wasShown == false)
        try overlay.dismiss()
        try pause.show(in: harness.player.view)
        #expect(pause.wasShown)
    }

    @Test func anOverlaysClockFreezesWhileTheAppIsNotActive() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "p10c", duration: 300))
        try ad.show(in: harness.player.view)
        await sleepMs(100)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        await sleepMs(400)
        #expect(delegate.endReasons.isEmpty, "frozen: 400 ms in the background did not count")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(await waitUntil(1) { delegate.endReasons == [.completed] }, "the remaining ~200 ms run on foreground")
    }

    @Test func anOverlayShownWhileInactiveStartsItsClockOnActivation() async throws {
        Environment.isApplicationActive = { false }
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "p10d", duration: 150))
        try ad.show(in: harness.player.view)
        await sleepMs(300)
        #expect(delegate.endReasons.isEmpty)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(await waitUntil(1) { delegate.endReasons == [.completed] })
    }

    @Test func aPagesCloseWithReasonCompleteEndsCompletedWithoutACloseBeacon() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i16"))
        try ad.show(from: window.root)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.complete", ["playhead": 10_000])
        send(ad, "ad.close", ["reason": "complete"])
        #expect(delegate.endReasons == [.completed], "the page ended itself: nobody closed anything")
        #expect(ad.isCompleted)
        let fired = await beacons()
        #expect(fired.contains("complete") && !fired.contains("close"), "nobody closed anything")
    }

    @Test func anOverlayIsRemovedBySDKWhenItsDurationElapses() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "p10a", duration: 200))
        var sent: [String] = []
        ad.bridge.onSend = { type, _ in if type != "ad.exposure" { sent.append(type) } }
        try ad.show(in: harness.player.view)
        #expect(ad.duration == 0.2)
        #expect(delegate.endReasons.isEmpty)
        #expect(await waitUntil(1) { delegate.endReasons == [.completed] }, "the SDK's clock, not the app's")
        #expect(ad.hasEnded)
        #expect(ad.isCompleted, "the duration elapsed")
        #expect(sent == ["ad.show", "ad.hide"])
        #expect(harness.player.view.subviews.isEmpty)
        let fired = await beacons()
        #expect(fired.contains("overlayViewDuration"))
        #expect(!fired.contains("close"))
        try ad.dismiss()
        #expect(delegate.endReasons.count == 1, "exactly once")
    }

    @Test func dismissBeforeTheDurationEndsAnOverlayEarlyAndStopsTheClock() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "p10b", duration: 150))
        try ad.show(in: harness.player.view)
        try ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
        #expect(ad.isCompleted == false, "ended before its duration")
        await sleepMs(250)
        #expect(delegate.endReasons == [.dismissed], "the duration clock was cancelled")
    }

    @Test func anOverlayWithoutADurationStaysUntilTheAppEndsIt() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p10e", format: "overlay", position: "bottom", size: ["width": 320, "height": 90, "scalable": true, "maintainAspectRatio": true]))
        #expect(ad.duration == nil, "no duration on the wire: a sticky overlay")
        try ad.show(in: harness.player.view)
        await sleepMs(150)
        #expect(delegate.endReasons.isEmpty, "no clock runs")
        try ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
        #expect(await beacons().contains("overlayViewDuration"))
    }

    @Test func aPauseAdHasNoDurationAndStaysUntilDismissed() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p10c"))
        #expect(ad.duration == nil)
        try ad.show(in: harness.player.view)
        await sleepMs(150)
        #expect(delegate.endReasons.isEmpty)
        try ad.dismiss()
    }

    @Test func dismissEndsWithDismissedAndFiresOverlayViewDurationNotClose() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.ad(id: "p10"))
        var sent: [String] = []
        ad.bridge.onSend = { type, _ in if type != "ad.exposure" { sent.append(type) } }
        try ad.show(in: harness.player.view)
        try ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
        #expect(ad.hasEnded)
        #expect(sent == ["ad.show", "ad.hide"])
        #expect(harness.player.view.subviews.isEmpty, "the host view is gone")
        let fired = await beacons()
        #expect(fired.contains("overlayViewDuration"))
        #expect(!fired.contains("close"))
        try ad.dismiss()
        #expect(delegate.endReasons.count == 1, "exactly once")
        #expect(ads.isDestroyed == false)
    }

    @Test func dismissBeforeShowDoesNothing() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p11"))
        try ad.dismiss()
        #expect(delegate.events.isEmpty)
        #expect(ad.isReady)
    }

    // MARK: The page's events after show

    @Test func closeEndsWithClosedAndFiresClose() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p12"))
        try ad.show(in: harness.player.view)
        send(ad, "ad.close", ["reason": "close"])
        #expect(delegate.endReasons == [.closed])
        let fired = await beacons()
        #expect(fired.contains("close"))
        #expect(fired.contains("overlayViewDuration"))
    }

    @Test func resumeEndsWithResumed() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p13", position: "fullscreen", size: nil))
        try ad.show(in: harness.player.view)
        send(ad, "ad.close", ["reason": "resume"])
        #expect(delegate.endReasons == [.resumed])
    }

    @Test func aPauseAdsVideoCompletingDoesNotChangeHowItsCloseEnds() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p13v", creative: "video", position: "fullscreen", size: nil))
        try ad.show(in: harness.player.view)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.complete", ["playhead": 6000])
        #expect(ad.hasEnded == false, "a pause ad outlives its video")
        send(ad, "ad.close", ["reason": "resume"])
        #expect(delegate.endReasons == [.resumed], "the gesture: only Resume resumes the content")
        #expect(ad.isCompleted, "and the video did run to its end")
        let fired = await beacons()
        #expect(fired.contains("complete") && fired.contains("close") && fired.contains("overlayViewDuration"))
    }

    @Test func overlayViewDurationCarriesTheActiveTimeOnScreenInMilliseconds() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p13d"))
        try ad.show(in: harness.player.view)
        await sleepMs(120)
        try ad.dismiss()
        _ = await beacons()
        let ovd = try #require(harness.server.beacons.first { $0.event == "overlayViewDuration" }?.query["ovd"].flatMap(Int.init))
        #expect(ovd >= 100 && ovd < 400, "[VIEWDURATION] is ms on screen: \(ovd)")
    }

    @Test func showPicksTheLargestSizeThatFitsTheViewUnscaled() async throws {
        let wide: [String: Any] = ["width": 728, "height": 90, "scalable": true, "maintainAspectRatio": true]
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p13s", format: "overlay", position: "bottom", size: ["width": 320, "height": 90, "scalable": true, "maintainAspectRatio": true], moreSizes: [wide], duration: 6000))
        #expect(ad.sizes == [VideoAd.Size(width: 320, height: 90), VideoAd.Size(width: 728, height: 90)])
        #expect(ad.size == VideoAd.Size(width: 320, height: 90), "the default before show")
        var shown: [String: Any]?
        ad.bridge.onSend = { type, payload in if type == "ad.show" { shown = payload } }
        let landscape = UIView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.add(landscape)
        try ad.show(in: landscape)
        #expect(ad.size == VideoAd.Size(width: 728, height: 90), "the player turned out wide: the wide variant")
        #expect((shown?["size"] as? [String: Int]) == ["width": 728, "height": 90], "the page is told which variant")
        #expect(try #require(landscape.subviews.last).frame == CGRect(x: 58, y: 300, width: 728, height: 90))
        try ad.dismiss()
    }

    @Test func showFallsBackToTheBestScaledSizeWhenNoneFits() async throws {
        let wide: [String: Any] = ["width": 728, "height": 90, "scalable": true, "maintainAspectRatio": true]
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p13t", format: "overlay", position: "bottom", size: ["width": 600, "height": 100, "scalable": true, "maintainAspectRatio": true], moreSizes: [wide], duration: 6000))
        try ad.show(in: harness.player.view)   // 390 wide: 600×100 fits at 0.65, 728×90 at 0.54
        #expect(ad.size == VideoAd.Size(width: 600, height: 100), "the variant with the best scale")
        #expect(try #require(harness.player.view.subviews.last).frame.width == 390)
        try ad.dismiss()
    }

    @Test func clickOpensTheURLFiresClickAndTellsTheDelegate() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p14"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://brand.test/offer", "area": "cta"])
        #expect(delegate.clicks == [VideoAd.Click(url: URL(string: "https://brand.test/offer")!, area: .other("cta"))])
        #expect(opened.map(\.absoluteString) == ["https://brand.test/offer"])
        #expect(await beacons().contains("click"))
        #expect(ad.hasEnded == false, "a click does not end the ad")
    }

    @Test func clickFallsBackWhenTheDeepLinkCannotOpen() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p15"))
        var opened: [String] = []
        Environment.openURL = { url, completion in opened.append(url.absoluteString); completion(url.scheme == "https") }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "brandapp://offer", "fallbackUrl": "https://brand.test/offer"])
        #expect(opened == ["brandapp://offer", "https://brand.test/offer"])
    }

    @Test func adChoicesOpensWithoutAClickAndFiresIconClick() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p16"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"])
        #expect(opened.count == 1)
        #expect(delegate.clicks.isEmpty, "not a click")
        let fired = await beacons()
        #expect(fired.contains("iconClick"))
        #expect(!fired.contains("click"))
    }

    @Test func errorAfterShowIsDidFailThenDidEndFailed() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p17"))
        try ad.show(in: harness.player.view)
        send(ad, "ad.error", ["code": 405])
        #expect(delegate.events.suffix(2) == ["fail", "end:failed"])
        guard case .creativeFailed(let code) = delegate.failures.first else { Issue.record("expected creativeFailed"); return }
        #expect(code == 405)
        let fired = await beacons()
        #expect(fired.contains("error"))
        #expect(harness.server.beacons.first { $0.event == "error" }?.query["code"] == "405")
    }

    @Test func errorWhileLoadedButUnshownEndsTheBidSilently() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p18"))
        send(ad, "ad.error", ["code": 502])
        #expect(ad.invalidationReason == .creativeFailed(code: 502))
        #expect(ad.bid?.invalidationReason == .creativeFailed(code: 502))
        #expect(ad.isReady == false)
        #expect(delegate.events.isEmpty, "nothing is delivered before show")
        #expect(await beacons().contains("error"))
    }

    // MARK: Video

    @Test func videoImpressionWaitsForTheFirstFrame() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i3"))
        try ad.show(from: window.root)
        #expect(delegate.events.isEmpty, "no impression at show for a video")
        var fired = await beacons()
        #expect(fired.contains("creativeView") && !fired.contains("impression"))
        send(ad, "video.start", ["playhead": 0])
        #expect(delegate.events == ["impression"])
        fired = await beacons()
        #expect(fired.contains("impression") && fired.contains("start"))
        send(ad, "video.start", ["playhead": 0])
        #expect(delegate.events.filter { $0 == "impression" }.count == 1)
    }

    @Test func videoEventsFireTheirBeaconsWithTheAdPlayhead() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i4"))
        try ad.show(from: window.root)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.firstQuartile", ["playhead": 2500])
        send(ad, "video.pause", ["playhead": 3000])
        send(ad, "video.resume", ["playhead": 3000])
        send(ad, "video.mute", ["playhead": 3100])
        send(ad, "video.unmute", ["playhead": 3200])
        send(ad, "video.progress", ["offset": 5000, "playhead": 5000])
        send(ad, "video.midpoint", ["playhead": 5000])
        send(ad, "video.thirdQuartile", ["playhead": 7500])
        let fired = await beacons()
        for event in ["start", "firstQuartile", "pause", "resume", "mute", "unmute", "progress", "midpoint", "thirdQuartile"] {
            #expect(fired.contains(event), Comment(rawValue: event))
        }
        #expect(harness.server.beacons.first { $0.event == "pause" }?.query["aph"] == "00:00:03.000")
    }

    @Test func completeFiresCompleteAndTheEndCardsCreativeView() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i5"))
        try ad.show(from: window.root)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.complete", ["playhead": 10_000])
        #expect(ad.isCompleted)
        #expect(ad.hasEnded == false, "the end card is up")
        let fired = await beacons()
        #expect(fired.contains("complete"))
        #expect(fired.contains("creativeView(endCard)"))
        #expect(ad.isCompleted, "the video ran to its end")
        send(ad, "ad.close", ["reason": "close"])
        #expect(delegate.endReasons == [.closed], "the ✕ is .closed in every format; isCompleted says the video was watched")
        #expect(ad.isCompleted)
    }

    @Test func endCardClickUsesTheEndCardsEntry() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i6"))
        Environment.openURL = { _, completion in completion(true) }
        try ad.show(from: window.root)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.complete", ["playhead": 10_000])
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://brand.test", "area": "endCard"])
        let fired = await beacons()
        #expect(fired.contains("click(endCard)"))
        #expect(!fired.contains("click"), "the creative's own click entry stays unfired")
    }

    @Test func skipEndsWithSkipped() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i7"))
        try ad.show(from: window.root)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.skip", ["playhead": 6000])
        #expect(delegate.endReasons == [.skipped])
        let fired = await beacons()
        #expect(fired.contains("skip"))
        #expect(!fired.contains("overlayViewDuration"), "linear ads have no view duration")
        #expect(harness.server.beacons.first { $0.event == "skip" }?.query["aph"] == "00:00:06.000")
    }

    // MARK: show(from:)

    @Test func showFromPresentsFullScreenAndTheSDKDismissesAtTheEnd() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i9"))
        try ad.show(from: window.root)
        #expect(await waitUntil { self.window.root.presentedViewController != nil })
        let presented = try #require(window.root.presentedViewController as? LinearViewController)
        #expect(presented.modalPresentationStyle == .fullScreen)
        #expect(presented.view.subviews.first === ad.bridge.webView)
        #expect(presented.prefersStatusBarHidden)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.skip", ["playhead": 1000])
        #expect(delegate.endReasons == [.skipped])
        // The package test runner has no window scene, so UIKit never finishes a transition here; the
        // SDK's request to dismiss is what can be checked. The example's --demo run covers the real thing.
        #expect(presented.isEndingByAd)
        #expect(presented.view.subviews.isEmpty || presented.view.subviews.first !== ad.bridge.webView || ad.hasEnded)
    }

    @Test func showFromWhenNotOnScreenThrowsPresenterUnavailableAndKeepsTheAd() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i10"))
        let detached = UIViewController()
        do { try ad.show(from: detached) } catch VideoAdError.presenterUnavailable {} catch { Issue.record("expected presenterUnavailable") }
        #expect(ad.isReady, "retryable")
    }

    @Test func showFromWhenAlreadyPresentingThrowsPresenterUnavailable() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i11"))
        let other = UIViewController()
        window.root.present(other, animated: false)
        do { try ad.show(from: window.root) } catch VideoAdError.presenterUnavailable {} catch { Issue.record("expected presenterUnavailable") }
        window.root.dismiss(animated: false)
        #expect(ad.isReady)
    }

    @Test func showWithoutAPresenterUsesTheKeyWindowsTopViewController() async throws {
        // The package runner never completes a modal transition, so the "top" here is the root; the
        // walk through presentedViewController is covered by the example's --demo run.
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i13"))
        Environment.keyWindow = { [window] in window.window }
        try ad.show()
        #expect(await waitUntil { self.window.root.presentedViewController is LinearViewController })
        #expect(ad.wasShown)
    }

    @Test func showWithoutAPresenterAndNoKeyWindowThrowsPresenterUnavailableAndKeepsTheAd() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i14"))
        Environment.keyWindow = { nil }
        do { try ad.show() } catch VideoAdError.presenterUnavailable {} catch { Issue.record("expected presenterUnavailable") }
        #expect(ad.isReady, "retryable, or pass the controller")
    }

    @Test func aLinearAdsCloseBeforeCompleteIsASkip() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i15"))
        try ad.show(from: window.root)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "ad.close", ["reason": "close"])
        #expect(delegate.endReasons == [.skipped], "a close before the end is a skip")
        #expect(ad.isCompleted == false)
        let fired = await beacons()
        #expect(fired.contains("skip") && !fired.contains("close"))
    }

    @Test func showFromOnAPauseAdThrowsWrongPresentation() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p19"))
        do { try ad.show(from: window.root) } catch VideoAdError.wrongPresentation {} catch { Issue.record("expected wrongPresentation, got \(error)") }
        #expect(ad.isReady)
    }

    @Test func dismissOnALinearAdThrowsWrongPresentation() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i19"))
        try ad.show(from: window.root)
        do { try ad.dismiss() } catch VideoAdError.wrongPresentation {} catch { Issue.record("expected wrongPresentation, got \(error)") }
        #expect(delegate.endReasons.isEmpty, "still on screen")
        send(ad, "video.skip", ["playhead": 1000])
        #expect(delegate.endReasons == [.skipped])
    }

    @Test func dismissalFromOutsideIsInterrupted() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i12"))
        try ad.show(from: window.root)
        #expect(await waitUntil { self.window.root.presentedViewController != nil })
        let presented = try #require(window.root.presentedViewController as? LinearViewController)
        // What viewDidDisappear sees when the presenter is dismissed underneath the ad.
        presented.viewDisappeared(isBeingDismissed: true, isMovingFromParent: false, hasPresenter: true)
        #expect(delegate.endReasons == [.interrupted])
        #expect(ad.hasEnded)
        let fired = await beacons()
        #expect(!fired.contains("close") && !fired.contains("skip"))
        presented.viewDisappeared(isBeingDismissed: true, isMovingFromParent: false, hasPresenter: true)
        #expect(delegate.endReasons.count == 1)
    }

    @Test func destroyWhileAnLinearIsUpEndsWithDestroyedAndDismisses() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.linearAd(id: "i13"))
        try ad.show(from: window.root)
        send(ad, "video.start", ["playhead": 0])
        #expect(await waitUntil { self.window.root.presentedViewController != nil })
        let presented = try #require(window.root.presentedViewController as? LinearViewController)
        ads.destroy()
        #expect(delegate.endReasons == [.destroyed])
        #expect(presented.isEndingByAd, "the SDK asked UIKit to dismiss")
        presented.viewDisappeared(isBeingDismissed: true, isMovingFromParent: false, hasPresenter: true)
        #expect(delegate.endReasons == [.destroyed], "the ad's own dismissal is not an interruption")
        let fired = await beacons()
        #expect(!fired.contains("close") && !fired.contains("overlayViewDuration"), "no VAST event for an app abort")
    }

    // MARK: Ownership

    @Test func theSDKRetainsAShowingAdUntilItEnds() async throws {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        weak var weakAd: VideoAd?
        let delegate = RecordingDelegate()
        try autoreleasepool {
            let ad = makeLoose(Fixtures.ad(id: "p20"), in: ads)
            ad.delegate = delegate
            send(ad, "ad.loaded")
            try ad.show(in: harness.player.view)
            weakAd = ad
        }
        #expect(weakAd != nil, "retained while showing")
        #expect(KontextVideo.shared.adOnScreen === weakAd)
        try weakAd?.dismiss()
        #expect(delegate.endReasons == [.dismissed])
        #expect(KontextVideo.shared.adOnScreen == nil)
        owners.bids.removeAll()
        #expect(await waitUntil { weakAd == nil }, "released after didEnd")
    }

    @Test func anAdOnScreenIgnoresInvalidationAndFinishesNormally() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p21", expires: 30_000))
        try ad.show(in: harness.player.view)
        ad.didInvalidate(.expired)
        ad.bid?.invalidate(.expired)
        advanceClock(by: 31)
        #expect(delegate.endReasons.isEmpty, "expiry does not touch an ad on screen")
        #expect(ad.invalidationReason == nil)
        try ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
    }

    @Test func dismissAfterTheEndDoesNothing() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p22"))
        try ad.show(in: harness.player.view)
        try ad.dismiss()
        try ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
    }
}
}
