import AVFoundation
import Foundation
@testable import KontextVideoSDK
import Testing

/// `VideoAds`: placements, every way `load` answers, the busy rule, `start()`, targeting changes,
/// `destroy()` and deallocation. Pages are real: the in-process frame server answers the WebView.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdsTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()

    init() {
        pages.install()
    }

    private func makeAds(content: String = "ep-1", player: TestPlayer? = nil) async -> VideoAds {
        _ = await harness.initialize()
        return (player ?? harness.player).ads(for: .init(id: content, language: "en"))
    }

    private func loadError(_ work: () async throws -> VideoAd) async -> VideoAdError? {
        do {
            _ = try await work()
            Issue.record("expected a throw")
            return nil
        } catch let error as VideoAdError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    // MARK: Placements

    @Test func sameTypedLookupReturnsTheSameObject() async {
        let ads = await makeAds()
        #expect(ads.pausePlacement("x") === ads.pausePlacement("x"))
        #expect(ads.overlayPlacement("x") === ads.overlayPlacement("x"))
        #expect(ads.interstitialPlacement("x") === ads.interstitialPlacement("x"))
        #expect(ads.pausePlacement("x") !== ads.pausePlacement("y"))
        #expect(ads.pausePlacement("x").id == "x")
    }

    @Test func differentTypesForOneIdAreDifferentObjectsSharingTheState() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.adsResponse(Fixtures.ad(id: "img-1", placementId: "x"))), delay: 0.3) }
        let pause = ads.pausePlacement("x")
        let interstitial = ads.interstitialPlacement("x")
        let first = Task { try await pause.load() }
        await sleepMs(50)
        let error = await loadError { try await interstitial.load() }
        guard case .placementBusy = error else { Issue.record("expected placementBusy, got \(String(describing: error))"); return }
        _ = try? await first.value
    }

    // MARK: load: the happy path

    @Test func loadReturnsAReadyAdWithTheRequestsFormatAndOptions() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-1", placementId: "pause"))
        let ad = try await ads.pausePlacement("pause").load(PauseOptions(positions: [.top, .fullscreen]))
        #expect(ad.isReady)
        #expect(ad.id == "img-1")
        #expect(ad.placementId == "pause")
        #expect(ad.format == .pause)
        let request = harness.server.requests(to: "/v2/video/ads").first?.body
        #expect(request?["format"] as? String == "pause")
        #expect(request?["placementId"] as? String == "pause")
        #expect((request?["options"] as? [String: Any])?["positions"] as? [String] == ["top", "fullscreen"])
        #expect((request?["video"] as? [String: Any])?["id"] as? String == "ep-1")
        #expect((request?["player"] as? [String: Any])?["playhead"] as? Int == 0, "the playhead read at request time")
        #expect(pages.served == ["img-1"], "the page loaded")
        #expect(await waitUntil { self.harness.server.beacons.map(\.event).contains("loaded") }, "the loaded beacon fires at ad.loaded")
    }

    @Test func loadWaitsForInitInFlight() async throws {
        harness.server.on("/v2/init") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.initEnabled()), delay: 0.2) }
        KontextVideo.shared.initialize(with: harness.configuration, completion: nil)
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        harness.serve(Fixtures.ad(id: "img-2"))
        let ad = try await ads.pausePlacement("pause").load()
        #expect(ad.isReady)
        #expect(KontextVideo.shared.state == .enabled)
    }

    @Test func loadCarriesThePlayheadReadAtRequestTime() async throws {
        let ads = await makeAds()
        harness.player.playhead = 12.5
        harness.serve(Fixtures.ad(id: "img-3"))
        _ = try await ads.pausePlacement("pause").load()
        let player = harness.server.requests(to: "/v2/video/ads").first?.body?["player"] as? [String: Any]
        #expect(player?["playhead"] as? Int == 12_500)
    }

    @Test func loadSendsConsentFromTheCMPStorage() async throws {
        Environment.consentDefaults.set("TC-STR", forKey: "IABTCF_TCString")
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-4"))
        _ = try await ads.pausePlacement("pause").load()
        let regulatory = harness.server.requests(to: "/v2/video/ads").first?.body?["regulatory"] as? [String: Any]
        #expect(regulatory?["gdprConsent"] as? String == "TC-STR")
    }

    // MARK: load: refusals before a request

    @Test func loadBeforeInitializeThrowsNotInitialized() async {
        Environment.assertionFailure = { _ in }
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .notInitialized = error else { Issue.record("expected notInitialized, got \(String(describing: error))"); return }
        #expect(harness.server.requests(to: "/v2/video/ads").isEmpty)
    }

    @Test func loadWhenInitFailedThrowsInitializationFailed() async {
        harness.server.on("/v2/init", .failure(.timedOut))
        let ads = await makeAds()
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .initializationFailed = error else { Issue.record("expected initializationFailed, got \(String(describing: error))"); return }
    }

    @Test func loadWhenDisabledThrowsDisabled() async {
        harness.server.on("/v2/init", .json(Fixtures.disabled("publisherDisabled")))
        let ads = await makeAds()
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .disabled(let reason) = error else { Issue.record("expected disabled"); return }
        #expect(reason == "publisherDisabled")
    }

    @Test func loadAfterDestroyThrowsDestroyedEvenOnAKeptPlacement() async {
        let ads = await makeAds()
        let placement = ads.pausePlacement("pause")
        ads.destroy()
        let kept = await loadError { try await placement.load() }
        guard case .destroyed = kept else { Issue.record("expected destroyed"); return }
        let fresh = await loadError { try await ads.overlayPlacement("overlay").load() }
        guard case .destroyed = fresh else { Issue.record("expected destroyed"); return }
        #expect(ads.isDestroyed)
    }

    @Test func loadBeforeNextRequestAtIsAnOrdinaryRequest() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.overlayAd(id: "img-5"), nextRequestAt: 25_000)
        let ad = try await ads.overlayPlacement("overlay").load()
        #expect(ads.nextRequestAt["overlay"] == 25_000, "remembered for timed mode")
        ad.invalidate(.targetingChanged)
        harness.player.playhead = 10
        harness.serve(Fixtures.overlayAd(id: "img-6"))
        _ = try await ads.overlayPlacement("overlay").load()
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2, "nextRequestAt is a recommendation, not a rule")
    }

    // MARK: load: the busy rule

    @Test func loadWhileLoadingIsBusy() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.adsResponse(Fixtures.ad(id: "img-7"))), delay: 0.3) }
        let placement = ads.pausePlacement("pause")
        let first = Task { try await placement.load() }
        await sleepMs(50)
        let error = await loadError { try await placement.load() }
        guard case .placementBusy = error else { Issue.record("expected placementBusy"); return }
        _ = try await first.value
    }

    @Test func loadWhileLoadedButUnshownIsBusy() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-8"))
        let ad = try await ads.pausePlacement("pause").load()
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .placementBusy = error else { Issue.record("expected placementBusy"); return }
        withExtendedLifetime(ad) {}
    }

    @Test func droppingTheAdFreesThePlacement() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-9"))
        var ad: VideoAd? = try await ads.pausePlacement("pause").load()
        ad = nil
        harness.serve(Fixtures.ad(id: "img-10"))
        let next = try await ads.pausePlacement("pause").load()
        #expect(next.id == "img-10")
    }

    @Test func loadWhileTheAdIsOnScreenIsAllowed() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-11"))
        let ad = try await ads.pausePlacement("pause").load()
        try ad.show(in: harness.player.view)
        harness.serve(Fixtures.ad(id: "img-12"))
        let next = try await ads.pausePlacement("pause").load()
        #expect(next.id == "img-12", "the next ad loads while the current one shows")
        #expect(ad.hasEnded == false, "the showing ad is untouched")
        let busy = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .placementBusy = busy else { Issue.record("expected placementBusy: one unshown ad at a time"); return }
        ad.dismiss()
        #expect(next.isReady)
        try next.show(in: harness.player.view)
        next.dismiss()
    }

    // MARK: load: what the server answers

    @Test func noFillIsThrownWithTheReason() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("frequencyCap")))
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .noFill(let reason) = error else { Issue.record("expected noFill"); return }
        #expect(reason == "frequencyCap")
        #expect(error?.description == "no fill (frequencyCap)")
    }

    @Test func retryAfterIsTheOneRetryTheSDKDoesItself() async throws {
        let ads = await makeAds()
        var calls = 0
        harness.server.on("/v2/video/ads") { _ in
            calls += 1
            return calls == 1 ? .json(Fixtures.noFill("temporaryError", retryAfter: 50)) : .json(Fixtures.adsResponse(Fixtures.ad(id: "img-13")))
        }
        let ad = try await ads.pausePlacement("pause").load()
        #expect(ad.id == "img-13")
        let ids = harness.server.requests(to: "/v2/video/ads").map { $0.body?["requestId"] as? String }
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1], "a new request, not a replay")
    }

    @Test func noFillAfterTheRetryIsThrown() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("temporaryError", retryAfter: 20)))
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .noFill = error else { Issue.record("expected noFill"); return }
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2, "retried once, never in a loop")
    }

    @Test func disabledResponseSwitchesTheSDKOff() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("appVersionDisabled")))
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .disabled(let reason) = error else { Issue.record("expected disabled"); return }
        #expect(reason == "appVersionDisabled")
        #expect(KontextVideo.shared.state == .disabled(reason: "appVersionDisabled"))
    }

    @Test func unknownPlacementIsAnInvalidPlacement() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("unknownPlacement", title: "unknown placementId \"nope\""), status: 400))
        let error = await loadError { try await ads.pausePlacement("nope").load() }
        guard case .invalidPlacement(.unknown(let id)) = error else { Issue.record("expected unknown placement, got \(String(describing: error))"); return }
        #expect(id == "nope")
        #expect(error?.description == "placement \"nope\" does not exist for this publisher token")
    }

    @Test func formatMismatchParsesTheExpectedFormat() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("placementFormatMismatch", title: "x", detail: "expected overlay, got interstitial"), status: 400))
        let error = await loadError { try await ads.interstitialPlacement("episode-overlay").load() }
        guard case .invalidPlacement(.formatMismatch(let id, let expected, let actual)) = error else { Issue.record("expected formatMismatch"); return }
        #expect(id == "episode-overlay")
        #expect(expected == .overlay)
        #expect(actual == .interstitial)
        #expect(error?.description == "placement \"episode-overlay\" is an overlay placement, not interstitial")
    }

    @Test func formatMismatchWithoutDetailStillNamesTheActualFormat() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("placementFormatMismatch"), status: 400))
        let error = await loadError { try await ads.pausePlacement("p").load() }
        guard case .invalidPlacement(.formatMismatch(_, let expected, let actual)) = error else { Issue.record("expected formatMismatch"); return }
        #expect(expected == nil)
        #expect(actual == .pause)
        #expect(error?.description == "placement \"p\" is not a pause placement")
    }

    @Test func otherClientErrorsAreRequestErrors() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("invalidRequest"), status: 400))
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .request(let underlying) = error, let apiError = underlying as? APIError, case .http(400, _) = apiError else { Issue.record("expected request(http 400)"); return }
    }

    @Test func transportFailureIsARequestErrorWithoutARetry() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .failure(.timedOut))
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .request = error else { Issue.record("expected request"); return }
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1, "ads requests are never retried by the SDK")
    }

    @Test func creativeThatNeverLoadsThrowsCreativeFailedWithTheGeneralCode() async {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "dead-1"))
        let error = await loadError { try await ads.pausePlacement("pause").load() }
        guard case .creativeFailed(let code) = error else { Issue.record("expected creativeFailed, got \(String(describing: error))"); return }
        #expect(code == 500, "NonLinear: 500")
        #expect(await waitUntil { self.harness.server.beacons.map(\.event) == ["error"] })
        #expect(harness.server.beacons.first?.query["code"] == "500")
    }

    @Test func creativeThatReportsAnErrorThrowsItsCode() async {
        let ads = await makeAds()
        harness.serve(Fixtures.interstitialAd(id: "err-1"))
        let error = await loadError { try await ads.interstitialPlacement("interstitial").load() }
        guard case .creativeFailed(let code) = error else { Issue.record("expected creativeFailed"); return }
        #expect(code == 502)
        harness.serve(Fixtures.interstitialAd(id: "vid-1"))
        _ = try? await ads.interstitialPlacement("interstitial").load()
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2, "the placement was free again")
    }

    // MARK: Cancellation

    @Test func cancellingDuringTheRequestThrowsCancellationErrorAndFreesThePlacement() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.adsResponse(Fixtures.ad(id: "img-14"))), delay: 0.5) }
        let placement = ads.pausePlacement("pause")
        let task = Task { try await placement.load() }
        await sleepMs(50)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        harness.serve(Fixtures.ad(id: "img-15"))
        let next = try await placement.load()
        #expect(next.id == "img-15")
    }

    @Test func cancellingDuringThePageLoadStopsThePage() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "dead-2"))
        let placement = ads.pausePlacement("pause")
        let task = Task { try await placement.load() }
        #expect(await waitUntil { self.pages.served.contains("dead-2") })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        harness.serve(Fixtures.ad(id: "img-16"))
        _ = try await placement.load()
    }

    @Test func destroyDuringThePageLoadFailsTheLoad() async {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "dead-3"))
        let placement = ads.pausePlacement("pause")
        let task = Task { try await placement.load() }
        #expect(await waitUntil { self.pages.served.contains("dead-3") })
        ads.destroy()
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch let error as VideoAdError {
            switch error {
            case .destroyed, .invalidated(.destroyed): break
            default: Issue.record("expected destroyed, got \(error)")
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: the playhead, targeting, destroy

    @Test func playheadComesFromTheProviderOrTheTrackedPlayerOrIsZero() async {
        let ads = await makeAds()
        harness.player.playhead = 47
        #expect(ads.playheadMs == 47_000)
        ads.playheadProvider = { .nan }
        #expect(ads.playheadMs == 0, "never NaN")
        ads.playheadProvider = { -3 }
        #expect(ads.playheadMs == 0, "never negative")
        let player = AVPlayer()
        ads.trackPlayhead(of: player)
        #expect(ads.playheadProvider == nil, "tracking a player replaces the provider")
        #expect(ads.playheadMs == 0, "no item: 0")
        ads.playheadProvider = { 5 }
        #expect(ads.playheadMs == 5_000, "a provider replaces the tracked player")
        let bare = VideoAds(content: .init(id: "bare", language: "en"))
        #expect(bare.playheadMs == 0, "nothing set: the start of the video, what a prefetch sends")
        #expect(bare.playerSize == nil, "full screen by default")
    }

    @Test func aTrackedPlayerIsHeldWeakly() async {
        let ads = await makeAds()
        var player: AVPlayer? = AVPlayer()
        ads.trackPlayhead(of: player!)
        player = nil
        #expect(ads.playheadMs == 0)
    }

    @Test func targetingChangeInvalidatesUnshownAds() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-17"))
        let ad = try await ads.pausePlacement("pause").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        KontextVideo.shared.user = KontextVideo.User(id: "someone-else")
        #expect(ad.isReady == false)
        #expect(ad.invalidationReason == .targetingChanged)
        #expect(delegate.invalidations == [.targetingChanged])
        KontextVideo.shared.user = KontextVideo.User(id: "someone-else")
        #expect(delegate.invalidations.count == 1, "the same value again changes nothing")
        harness.serve(Fixtures.ad(id: "img-18"))
        _ = try await ads.pausePlacement("pause").load()
    }

    @Test func targetingChangeLeavesAnAdOnScreenAlone() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-19"))
        let ad = try await ads.pausePlacement("pause").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        try ad.show(in: harness.player.view)
        KontextVideo.shared.variantId = "b"
        #expect(delegate.invalidations.isEmpty)
        #expect(delegate.endReasons.isEmpty)
        ad.dismiss()
    }

    @Test func destroyInvalidatesLoadedAdsAndEndsShowingOnes() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-20"))
        let loaded = try await ads.pausePlacement("pause").load()
        harness.serve(Fixtures.overlayAd(id: "img-21"))
        let showing = try await ads.overlayPlacement("overlay").load()
        let loadedDelegate = RecordingDelegate()
        let showingDelegate = RecordingDelegate()
        loaded.delegate = loadedDelegate
        showing.delegate = showingDelegate
        try showing.show(in: harness.player.view)
        ads.destroy()
        #expect(loadedDelegate.invalidations == [.destroyed])
        #expect(showingDelegate.endReasons == [.destroyed])
        #expect(loaded.isReady == false)
        #expect(showing.hasEnded)
        ads.destroy()
        #expect(showingDelegate.endReasons.count == 1, "destroy twice does nothing more")
        #expect(throws: VideoAdError.self) { try loaded.show(in: harness.player.view) }
    }

    @Test func deallocationDoesWhatDestroyDoes() async throws {
        var ads: VideoAds? = await makeAds()
        harness.serve(Fixtures.ad(id: "img-22"))
        let ad = try await ads!.pausePlacement("pause").load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        ads = nil
        #expect(delegate.invalidations == [.destroyed])
        #expect(ad.isReady == false)
    }
}
}
