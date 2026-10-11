import Foundation
@testable import KontextVideoSDK
import Testing

/// Timed mode: the clock, windows opening and passing, `nextRequestAt`, seeks, and what runs when
/// nothing is to be watched. The playhead is the test's own number; the sample interval is 20 ms.
extension SerialSuites {
@Suite
@MainActor
struct TimedModeTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()
    private let window = TestWindow()
    private let timing = RecordingTimingDelegate()

    init() {
        pages.install()
        window.add(harness.player.view)
    }

    private func makeAds() async -> VideoAds {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"))
        ads.timingDelegate = timing
        return ads
    }

    private func windowed(_ id: String, from: Int, to: Int, duration: Int = 6000) -> [String: Any] {
        Fixtures.overlayAd(id: id, duration: duration).merging(["trigger": ["kind": "window", "from": from, "to": to]]) { $1 }
    }

    private func windowedInterstitial(_ id: String, from: Int, to: Int) -> [String: Any] {
        Fixtures.interstitialAd(id: id).merging(["trigger": ["kind": "window", "from": from, "to": to]]) { $1 }
    }

    private func ticks(_ n: Int = 3) async {
        await sleepMs(Int(VideoAds.sampleInterval * 1000) * n + 10)
    }

    /// Normal playback: the playhead advances in steps smaller than the seek threshold, a sample between.
    private func play(to target: TimeInterval) async {
        while harness.player.playhead < target {
            harness.player.playhead = min(target, harness.player.playhead + 1)
            await ticks(1)
        }
    }

    // MARK: Windows

    @Test func theWindowOpeningIsDeliveredOnTheAdsDelegateAndTheAppShowsIt() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w1", from: 20_000, to: 40_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        #expect(ad.trigger == .window(from: 20, to: 40))
        await ticks()
        #expect(delegate.windowsReached == 0, "before the window")
        await play(to: 20.1)
        #expect(await waitUntil { delegate.windowsReached == 1 })
        try ad.show(in: harness.player.view)
        #expect(delegate.events.contains("show"))
        await ticks()
        #expect(delegate.windowsReached == 1, "once")
        ad.dismiss()
    }

    @Test func loadResolvingInsideAnOpenWindowIsDeliveredOnTheNextTick() async throws {
        let ads = await makeAds()
        harness.player.playhead = 25
        harness.serve(windowed("img-w2", from: 20_000, to: 40_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        #expect(delegate.windowsReached == 0, "never from inside load")
        #expect(await waitUntil { delegate.windowsReached == 1 })
    }

    @Test func aWindowThatClosesUnshownDiscardsTheAdAndAsksForALoad() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w3", from: 20_000, to: 30_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        await play(to: 21)
        #expect(await waitUntil { delegate.windowsReached == 1 })
        await play(to: 24.5)   // a 6 s overlay no longer fits before 30
        #expect(await waitUntil { delegate.invalidations == [.windowPassed] })
        #expect(ad.isReady == false)
        #expect(timing.loadRequests.map(\.placementId) == ["overlay"])
        #expect(timing.loadRequests.first?.reason == .adDiscarded(.windowPassed))
        do { try ad.show(in: harness.player.view) } catch VideoAdError.invalidated(.windowPassed) {} catch { Issue.record("expected windowPassed") }
    }

    @Test func anOverlayIsOfferedOnlyWhileItsDurationFitsBeforeTheWindowEnd() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w4", from: 20_000, to: 24_000, duration: 6000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        await play(to: 20.5)
        #expect(await waitUntil { delegate.invalidations == [.windowPassed] }, "a 6 s overlay cannot fit in 3.5 s")
        #expect(delegate.windowsReached == 0)
    }

    @Test func anInterstitialWindowIsOpenUntilItsEnd() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowedInterstitial("vid-w5", from: 20_000, to: 21_000))
        let ad = try await ads.interstitialPlacement("interstitial").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        await play(to: 20.9)
        #expect(await waitUntil { delegate.windowsReached == 1 })
        await play(to: 21)
        #expect(await waitUntil { delegate.invalidations == [.windowPassed] })
    }

    @Test func aLoadInFlightThrowsWhenItsWindowPasses() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("dead-w6", from: 20_000, to: 30_000))
        let task = Task { try await ads.overlayPlacement("overlay").load() }
        await sleepMs(300)
        await play(to: 31)
        do {
            _ = try await task.value
            Issue.record("expected invalidated(.windowPassed)")
        } catch VideoAdError.invalidated(.windowPassed) {}
    }

    @Test func aPendingBidsWindowPassingDiscardsIt() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w7", from: 20_000, to: 30_000))
        let bid = try await ads.overlayPlacement("overlay").fetch()
        await play(to: 31)
        #expect(await waitUntil { bid.invalidationReason == .windowPassed })
        do { _ = try await bid.load() } catch VideoAdError.invalidated(.windowPassed) {} catch { Issue.record("expected windowPassed") }
        #expect(timing.loadRequests.first?.reason == .adDiscarded(.windowPassed))
    }

    @Test func contentPausedInsideTheWindowDeliversOnResume() async throws {
        let ads = await makeAds()
        harness.player.playhead = 19.9
        harness.serve(windowed("img-w8", from: 20_000, to: 40_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        await ticks()
        #expect(delegate.windowsReached == 0, "paused before the window: nothing fires")
        harness.player.playhead = 20.3
        #expect(await waitUntil { delegate.windowsReached == 1 }, "on the first sample after resume")
    }

    @Test func noDelegateAtTheWindowLogsAWarningAndCountsAsDelivered() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w9", from: 20_000, to: 40_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        await play(to: 21)
        #expect(await waitUntil { ad.windowDelivered })
        #expect(ad.isReady, "still showable by hand")
    }

    // MARK: nextRequestAt

    @Test func nextRequestAtIsReportedOncePerValue() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("frequencyCap", nextRequestAt: 30_000)))
        do { _ = try await ads.overlayPlacement("overlay").load() } catch VideoAdError.noFill {}
        #expect(ads.nextRequestAt["overlay"] == 30_000)
        await play(to: 29.9)
        await ticks()
        #expect(timing.loadRequests.isEmpty)
        await play(to: 30)
        #expect(await waitUntil { self.timing.loadRequests.count == 1 })
        #expect(timing.loadRequests.first?.placementId == "overlay")
        #expect(timing.loadRequests.first?.reason == .nextRequestReached)
        #expect(ads.nextRequestAt["overlay"] == nil)
        await play(to: 35)
        await ticks()
        #expect(timing.loadRequests.count == 1, "once")
    }

    // MARK: Seeks

    @Test func aSeekDiscardsPendingWindowedAdsForgetsThePlanAndAsksForLoads() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w10", from: 20_000, to: 40_000), nextRequestAt: 50_000)
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        await ticks()
        harness.player.playhead = 60   // forward past everything
        #expect(await waitUntil { delegate.invalidations == [.seeked] })
        #expect(ads.nextRequestAt.isEmpty)
        #expect(timing.loadRequests.count == 1, "one notification per placement")
        #expect(timing.loadRequests.first?.reason == .seeked)
        do { try ad.show(in: harness.player.view) } catch VideoAdError.invalidated(.seeked) {} catch { Issue.record("expected seeked") }
    }

    @Test func aBackwardSeekIsASeekToo() async throws {
        let ads = await makeAds()
        harness.player.playhead = 30
        harness.serve(windowed("img-w11", from: 40_000, to: 50_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        await ticks()
        harness.player.playhead = 5
        #expect(await waitUntil { delegate.invalidations == [.seeked] })
    }

    @Test func aSmallJumpIsNotASeek() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w12", from: 20_000, to: 40_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        await ticks()
        harness.player.playhead = 11.5
        await ticks()
        #expect(delegate.invalidations.isEmpty)
        #expect(ad.isReady)
    }

    @Test func aSeekOutOfAShowingOverlaysWindowInterruptsIt() async throws {
        let ads = await makeAds()
        harness.player.playhead = 21
        harness.serve(windowed("img-w13", from: 20_000, to: 40_000))
        let ad = try await ads.overlayPlacement("overlay").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        #expect(await waitUntil { delegate.windowsReached == 1 })
        try ad.show(in: harness.player.view)
        harness.player.playhead = 23
        await ticks()
        #expect(delegate.endReasons.isEmpty, "a jump within the window is fine")
        harness.player.playhead = 70
        #expect(await waitUntil { delegate.endReasons == [.interrupted] })
        #expect(await waitUntil { self.harness.server.beacons.map(\.event).contains("overlayViewDuration") })
    }

    @Test func manualAdsNeverRunTheClock() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-w14"))
        let ad = try await ads.pausePlacement("pause").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        harness.player.playhead = 500
        await ticks()
        #expect(delegate.events.isEmpty)
        #expect(timing.loadRequests.isEmpty)
        #expect(ad.isReady, "a manual ad does not care about seeks")
    }

    @Test func destroyStopsTheClock() async throws {
        let ads = await makeAds()
        harness.player.playhead = 10
        harness.serve(windowed("img-w15", from: 20_000, to: 40_000), nextRequestAt: 15_000)
        _ = try await ads.overlayPlacement("overlay").load()
        ads.destroy()
        await play(to: 16)
        await ticks()
        #expect(timing.loadRequests.isEmpty)
    }
}
}
