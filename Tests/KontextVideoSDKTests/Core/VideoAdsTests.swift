import AppTrackingTransparency
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

    // MARK: Loaders

    @Test func theThreeLoadersAreCreatedWithTheVideoAds() async {
        let ads = await makeAds()
        #expect(ads.format(.overlay) === ads.format(.overlay), "the same loader every time")
        #expect(ads.format(.pause).slot.format == .pause)
        #expect(ads.format(.linear).slot.format == .linear)
        #expect(ads.format(.overlay).slot.format == .overlay)
    }

    // MARK: the creation-time request

    @Test func declaredFormatsAreRequestedOnceAtCreationAndTheirAdsWaitInTheLoaders() async throws {
        _ = await harness.initialize()
        harness.serve(formats: [
            "linear": Fixtures.filledEntry(Fixtures.linearAd(id: "l1")),
            "pause": Fixtures.filledEntry(Fixtures.ad(id: "p1")),
        ])
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"), formats: [.linear(LinearOptions(timing: .preroll)), .pause()])
        let bid = try await ads.format(.pause).bid
        #expect(bid.id == "p1")
        let preroll = try await ads.format(.linear).load()
        #expect(preroll.id == "l1")
        let requests = harness.server.requests(to: "/v2/video/ads")
        #expect(requests.count == 1, "one request for both formats")
        let formats = requests.first?.body?["formats"] as? [[String: Any]]
        #expect(formats?.map { $0["format"] as? String } == ["linear", "pause"])
        #expect((formats?.first?["options"] as? [String: Any])?["timing"] as? String == "preroll")
        #expect(pages.served == ["l1"], "the pause bid is not rendered until load")
        withExtendedLifetime(bid) {}
    }

    @Test func aFormatsNoFillFromCreationIsThrownOnceThenAskedAgain() async throws {
        _ = await harness.initialize()
        harness.serve(formats: [
            "overlay": Fixtures.noFillEntry("frequencyCap", format: "overlay"),
            "pause": Fixtures.filledEntry(Fixtures.ad(id: "p2")),
        ])
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"), formats: [.overlay(), .pause()])
        let error = await loadError { try await ads.format(.overlay).load() }
        guard case .noFill(let reason) = error else { Issue.record("expected the creation-time no fill"); return }
        #expect(reason == "frequencyCap")
        harness.serve(Fixtures.overlayAd(id: "o2"))
        let overlay = try await ads.format(.overlay).load()
        #expect(overlay.id == "o2", "the next access asks again")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2)
    }

    @Test func anUndeclaredFormatFetchesOnFirstUse() async throws {
        _ = await harness.initialize()
        harness.serve(formats: ["pause": Fixtures.filledEntry(Fixtures.ad(id: "p3"))])
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"), formats: [.pause()])
        _ = try await ads.format(.pause).bid
        harness.serve(Fixtures.overlayAd(id: "o3"))
        let overlay = try await ads.format(.overlay).load()
        #expect(overlay.id == "o3")
        let bodies = harness.server.requests(to: "/v2/video/ads").compactMap { ($0.body?["formats"] as? [[String: Any]])?.map { $0["format"] as? String } }
        #expect(bodies.count == 2 && bodies.last == ["overlay"], "one format, with the default options")
    }

    @Test func aFailedCreationTimeRequestLeavesTheLoadersToFetch() async throws {
        _ = await harness.initialize()
        harness.server.on("/v2/video/ads", .json(["errors": [["code": "invalidRequest"]]], status: 500))
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"), formats: [.pause()])
        await sleepMs(100)
        harness.serve(Fixtures.ad(id: "p4"))
        let ad = try await ads.format(.pause).load()
        #expect(ad.id == "p4")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2)
    }

    @Test func fetchReplacesAnAnswerTheAppNeverTook() async throws {
        _ = await harness.initialize()
        harness.serve(formats: ["linear": Fixtures.filledEntry(Fixtures.linearAd(id: "l5"))])
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"), formats: [.linear()])
        harness.serve(Fixtures.linearAd(id: "l6"))
        let fresh = try await ads.format(.linear).fetch(LinearOptions(timing: .postroll))
        #expect(fresh.id == "l6")
        let held = try await ads.format(.linear).bid
        #expect(held === fresh, "bid is what fetch brought")
        let bodies = harness.server.requests(to: "/v2/video/ads").compactMap { $0.body?["formats"] as? [[String: Any]] }
        #expect((bodies.last?.first?["options"] as? [String: Any])?["timing"] as? String == "postroll")
    }

    @Test func aFormatListedTwiceIsAProgrammerErrorAndTheFirstCounts() async throws {
        var messages: [String] = []
        Environment.assertionFailure = { messages.append($0) }
        _ = await harness.initialize()
        harness.serve(formats: ["pause": Fixtures.filledEntry(Fixtures.ad(id: "p7"))])
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"), formats: [.pause(PauseOptions(positions: [.top])), .pause(PauseOptions(positions: [.fullscreen]))])
        _ = try await ads.format(.pause).bid
        #expect(messages.count == 1)
        let formats = harness.server.requests(to: "/v2/video/ads").first?.body?["formats"] as? [[String: Any]]
        #expect(formats?.count == 1)
        #expect((formats?.first?["options"] as? [String: Any])?["positions"] as? [String] == ["top"])
    }

    // MARK: refetch after end

    @Test func aPauseAdThatEndedIsRefetchedSoTheNextLoadRendersAtOnce() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "p1"))
        let ad = try await ads.format(.pause).load()
        try ad.show(in: harness.player.view)
        harness.serve(Fixtures.ad(id: "p2"))
        ad.dismiss()
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/video/ads").count == 2 }, "one request after the end, by itself")
        let next = try await ads.format(.pause).load()
        #expect(next.id == "p2")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2, "load() rendered the held answer, no third request")
        let formats = harness.server.requests(to: "/v2/video/ads").last?.body?["formats"] as? [[String: Any]]
        #expect(formats?.map { $0["format"] as? String } == ["pause"])
    }

    @Test func aLinearAdThatEndedIsNotRefetchedByDefault() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.linearAd(id: "l1"))
        let ad = try await ads.format(.linear).load()
        let window = TestWindow()
        try ad.show(from: window.root)
        ads.destroy()   // the one way an app ends a linear ad; didEnd(.destroyed) runs the same hook
        await sleepMs(100)
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1)
        withExtendedLifetime(window) {}
    }

    @Test func theRefetchPolicyIsPerFormatInTheConfiguration() async throws {
        _ = await harness.initialize(formats: [.pause: .init(refetch: .never)])
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"))
        harness.serve(Fixtures.ad(id: "p3"))
        let ad = try await ads.format(.pause).load()
        try ad.show(in: harness.player.view)
        ad.dismiss()
        await sleepMs(100)
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1, "never: the next load() fetches")
        #expect(KontextVideo.shared.configuration?.formats[.overlay]?.refetch == .afterEnd, "the other formats keep their defaults")
    }

    @Test func aRefetchedNoFillIsThrownOnceByTheNextLoad() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "p4"))
        let ad = try await ads.format(.pause).load()
        try ad.show(in: harness.player.view)
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("frequencyCap")))
        ad.dismiss()
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/video/ads").count == 2 })
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .noFill(let reason) = error else { Issue.record("expected the refetched no fill"); return }
        #expect(reason == "frequencyCap")
    }

    // MARK: load: the happy path

    @Test func loadReturnsAReadyAdWithTheRequestsFormatAndOptions() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-1"))
        let ad = try await ads.format(.pause).load(PauseOptions(positions: [.top, .fullscreen]))
        #expect(ad.isReady)
        #expect(ad.id == "img-1")
        #expect(ad.format == .pause)
        let request = harness.server.requests(to: "/v2/video/ads").first?.body
        let formats = request?["formats"] as? [[String: Any]]
        #expect(formats?.count == 1, "a loader asks for its one format")
        #expect(formats?.first?["format"] as? String == "pause")
        #expect(request?["placementId"] == nil, "no placement ids on the wire")
        #expect((formats?.first?["options"] as? [String: Any])?["positions"] as? [String] == ["top", "fullscreen"])
        #expect((request?["video"] as? [String: Any])?["id"] as? String == "ep-1")
        #expect((request?["player"] as? [String: Any])?["playhead"] as? Int == 0, "the playhead read at request time")
        #expect(pages.served == ["img-1"], "the page loaded")
        #expect(await waitUntil { self.harness.server.beacons.map(\.event).contains("loaded") }, "the loaded beacon fires at ad.loaded")
    }

    @Test func loadWaitsForInitInFlight() async throws {
        harness.server.on("/v2/config") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.initEnabled()), delay: 0.2) }
        KontextVideo.shared.initialize(with: harness.configuration, completion: nil)
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        harness.serve(Fixtures.ad(id: "img-2"))
        let ad = try await ads.format(.pause).load()
        #expect(ad.isReady)
        #expect(KontextVideo.shared.state == .enabled)
    }

    @Test func requestsAfterTheFirstShowCarryTheShownViewsBox() async throws {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep-1", language: "en"), playerSize: CGSize(width: 390, height: 220))
        harness.serve(Fixtures.ad(id: "img-3a"))
        let first = try await ads.format(.pause).load()
        harness.player.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)   // the real box turned out different
        try first.show(in: harness.player.view)
        harness.serve(Fixtures.ad(id: "img-3b"))
        _ = try await ads.format(.overlay).load()
        let players = harness.server.requests(to: "/v2/video/ads").compactMap { $0.body?["player"] as? [String: Any] }
        #expect(players.map { $0["width"] as? Int } == [390, 844], "the hint for the first request, the shown view's box after")
        #expect(players.map { $0["height"] as? Int } == [220, 390])
    }

    @Test func unshownAdsAcrossVideoAdsAreNotCounted() async throws {
        // No app-wide render budget: one pending ad per placement is the only bound.
        let ads = await makeAds()
        let other = harness.player.ads(for: .init(id: "ep-next", language: "en"))
        harness.serve(Fixtures.ad(id: "img-b1"))
        let a = try await ads.format(.pause).load()
        harness.serve(Fixtures.ad(id: "img-b2"))
        let b = try await ads.format(.overlay).load()
        harness.serve(Fixtures.ad(id: "img-b3"))
        let c = try await other.format(.pause).load()
        harness.serve(Fixtures.ad(id: "img-b4"))
        let d = try await other.format(.overlay).load()
        #expect(a.isReady && b.isReady && c.isReady && d.isReady)
        withExtendedLifetime((a, b, c, d)) {}
        other.destroy()
    }

    @Test func loadCarriesThePlayheadReadAtRequestTime() async throws {
        let ads = await makeAds()
        harness.player.playhead = 12.5
        harness.serve(Fixtures.ad(id: "img-3"))
        _ = try await ads.format(.pause).load()
        let player = harness.server.requests(to: "/v2/video/ads").first?.body?["player"] as? [String: Any]
        #expect(player?["playhead"] as? Int == 12_500)
    }

    @Test func loadSendsConsentFromTheCMPStorage() async throws {
        Environment.consentDefaults.set("TC-STR", forKey: "IABTCF_TCString")
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-4"))
        _ = try await ads.format(.pause).load()
        let regulatory = harness.server.requests(to: "/v2/video/ads").first?.body?["regulatory"] as? [String: Any]
        #expect(regulatory?["gdprConsent"] as? String == "TC-STR")
    }

    // MARK: load: refusals before a request

    @Test func loadBeforeInitializeThrowsNotInitialized() async {
        Environment.assertionFailure = { _ in }
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .notInitialized = error else { Issue.record("expected notInitialized, got \(String(describing: error))"); return }
        #expect(harness.server.requests(to: "/v2/video/ads").isEmpty)
    }

    @Test func loadWhenInitFailedThrowsInitializationFailed() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        let ads = await makeAds()
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .initializationFailed = error else { Issue.record("expected initializationFailed, got \(String(describing: error))"); return }
    }

    @Test func loadWhenDisabledThrowsDisabled() async {
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        let ads = await makeAds()
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .disabled(let reason) = error else { Issue.record("expected disabled"); return }
        #expect(reason == "publisherDisabled")
    }

    @Test func loadAfterDestroyThrowsDestroyedEvenOnAKeptLoader() async {
        let ads = await makeAds()
        let loader = ads.format(.pause)
        ads.destroy()
        let kept = await loadError { try await loader.load() }
        guard case .destroyed = kept else { Issue.record("expected destroyed"); return }
        let fresh = await loadError { try await ads.format(.overlay).load() }
        guard case .destroyed = fresh else { Issue.record("expected destroyed"); return }
        #expect(ads.isDestroyed)
    }

    // MARK: load: the busy rule

    @Test func loadWhileLoadingIsBusy() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.adsResponse(Fixtures.ad(id: "img-7"))), delay: 0.3) }
        let loader = ads.format(.pause)
        let first = Task { try await loader.load() }
        await sleepMs(50)
        let error = await loadError { try await loader.load() }
        guard case .formatBusy = error else { Issue.record("expected formatBusy"); return }
        _ = try await first.value
    }

    @Test func loadWhileLoadedButUnshownIsBusy() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-8"))
        let ad = try await ads.format(.pause).load()
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .formatBusy = error else { Issue.record("expected formatBusy"); return }
        withExtendedLifetime(ad) {}
    }

    @Test func droppingTheAdFreesTheLoader() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-9"))
        var ad: VideoAd? = try await ads.format(.pause).load()
        #expect(ad?.isReady == true)
        ad = nil
        harness.serve(Fixtures.ad(id: "img-10"))
        let next = try await ads.format(.pause).load()
        #expect(next.id == "img-10")
    }

    @Test func loadWhileTheAdIsOnScreenIsAllowed() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-11"))
        let ad = try await ads.format(.pause).load()
        try ad.show(in: harness.player.view)
        harness.serve(Fixtures.ad(id: "img-12"))
        let next = try await ads.format(.pause).load()
        #expect(next.id == "img-12", "the next ad loads while the current one shows")
        #expect(ad.hasEnded == false, "the showing ad is untouched")
        let busy = await loadError { try await ads.format(.pause).load() }
        guard case .formatBusy = busy else { Issue.record("expected formatBusy: one unshown ad at a time"); return }
        ad.dismiss()
        #expect(next.isReady)
        try next.show(in: harness.player.view)
        next.dismiss()
    }

    // MARK: load: what the server answers

    @Test func noFillIsThrownWithTheReason() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("frequencyCap")))
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .noFill(let reason) = error else { Issue.record("expected noFill"); return }
        #expect(reason == "frequencyCap")
        #expect(error?.description == "no fill (frequencyCap)")
    }

    @Test func aTemporaryErrorIsANoFillLikeAnyOtherNeverRetried() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("temporaryError")))
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .noFill("temporaryError") = error else { Issue.record("expected noFill"); return }
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1, "the SDK never retries an ads request")
    }

    @Test func disabledResponseSwitchesTheSDKOff() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("appVersionDisabled")))
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .disabled(let reason) = error else { Issue.record("expected disabled"); return }
        #expect(reason == "appVersionDisabled")
        #expect(KontextVideo.shared.state == .disabled(reason: "appVersionDisabled"))
    }

    @Test func aFormatWithoutAConfigurationIsANoFill() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("formatNotEnabled", format: "linear")))
        let error = await loadError { try await ads.format(.linear).load() }
        guard case .noFill(let reason) = error else { Issue.record("expected noFill, got \(String(describing: error))"); return }
        #expect(reason == "formatNotEnabled")
    }

    @Test func otherClientErrorsAreRequestErrors() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("invalidRequest"), status: 400))
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .request(let underlying) = error, let apiError = underlying as? APIError, case .http(400, _) = apiError else { Issue.record("expected request(http 400)"); return }
    }

    @Test func transportFailureIsARequestErrorWithoutARetry() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .failure(.timedOut))
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .request = error else { Issue.record("expected request"); return }
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1, "ads requests are never retried by the SDK")
    }

    @Test func creativeThatNeverLoadsThrowsCreativeFailedWithTheGeneralCode() async {
        let ads = await makeAds()
        FrameBridge.loadTimeout = 0.5   // the page is served in-process; the generous CI default would add 8 s
        harness.serve(Fixtures.ad(id: "dead-1"))
        let error = await loadError { try await ads.format(.pause).load() }
        guard case .creativeFailed(let code) = error else { Issue.record("expected creativeFailed, got \(String(describing: error))"); return }
        #expect(code == 500, "NonLinear: 500")
        #expect(await waitUntil { self.harness.server.beacons.map(\.event) == ["error"] })
        #expect(harness.server.beacons.first?.query["code"] == "500")
    }

    @Test func creativeThatReportsAnErrorThrowsItsCode() async {
        let ads = await makeAds()
        harness.serve(Fixtures.linearAd(id: "err-1"))
        let error = await loadError { try await ads.format(.linear).load() }
        guard case .creativeFailed(let code) = error else { Issue.record("expected creativeFailed"); return }
        #expect(code == 502)
        harness.serve(Fixtures.linearAd(id: "vid-1"))
        _ = try? await ads.format(.linear).load()
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2, "the placement was free again")
    }

    // MARK: Cancellation

    @Test func cancellingDuringTheRequestThrowsCancellationErrorAndFreesTheLoader() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.adsResponse(Fixtures.ad(id: "img-14"))), delay: 0.5) }
        let placement = ads.format(.pause)
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
        let placement = ads.format(.pause)
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
        let placement = ads.format(.pause)
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
        let ad = try await ads.format(.pause).load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        KontextVideo.shared.user = KontextVideo.User(id: "someone-else")
        #expect(ad.isReady == false)
        #expect(ad.invalidationReason == .targetingChanged)
        #expect(delegate.invalidations == [.targetingChanged])
        KontextVideo.shared.user = KontextVideo.User(id: "someone-else")
        #expect(delegate.invalidations.count == 1, "the same value again changes nothing")
        harness.serve(Fixtures.ad(id: "img-18"))
        _ = try await ads.format(.pause).load()
    }

    @Test func anATTStatusChangeIsATargetingChange() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-17a"))
        let ad = try await ads.format(.pause).load()   // the request noted the device's real status
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        let real = ATTrackingManager.trackingAuthorizationStatus
        KontextVideo.shared.noteTrackingAuthorization(real)
        #expect(delegate.invalidations.isEmpty, "the same status again changes nothing")
        KontextVideo.shared.noteTrackingAuthorization(real == .denied ? .authorized : .denied)
        #expect(delegate.invalidations == [.targetingChanged], "the viewer changed their mind in Settings")
    }

    @Test func targetingChangeLeavesAnAdOnScreenAlone() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-19"))
        let ad = try await ads.format(.pause).load()
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
        let loaded = try await ads.format(.pause).load()
        harness.serve(Fixtures.overlayAd(id: "img-21"))
        let showing = try await ads.format(.overlay).load()
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
        let ad = try await ads!.format(.pause).load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        ads = nil
        #expect(delegate.invalidations == [.destroyed])
        #expect(ad.isReady == false)
    }
}
}
