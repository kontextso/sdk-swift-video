import AVFoundation
import Foundation
@testable import KontextVideoSDK
import Testing

/// `VideoAds`: every way `format(_:)` answers, the request it sends (all formats, the session, `held`),
/// following the server (re-serve, replace, no-fill), the shared request and its races, the kill switch,
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

    private func makeAds(content: String = "ep-1") async -> VideoAds {
        _ = await harness.initialize()
        return harness.player.ads(for: .init(id: content, language: "en"))
    }

    private func error<T>(_ work: () async throws -> T) async -> VideoAdError? {
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

    /// The `notUsed` beacons that arrived. Expecting some: waits for that many (they travel through
    /// URLSession); expecting none: gives them 80 ms to show up.
    private func notUsedBeacons(expecting count: Int = 0) async -> [(adId: String, reason: String?)] {
        let arrived = { self.harness.server.beacons.filter { $0.event == "notUsed" }.map { ($0.adId, $0.query["reason"]) } }
        if count == 0 { await sleepMs(80) } else { _ = await waitUntil { arrived().count >= count } }
        return arrived()
    }

    // MARK: The request

    @Test func creatingAVideoAdsSendsNothing() async {
        _ = await makeAds()
        await sleepMs(50)
        #expect(harness.adsRequests.isEmpty)
    }

    @Test func formatAsksForAllFormatsWithTheSessionAndWhatItHolds() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p1"), "linear": Fixtures.linearAd(id: "vid-l1")])
        let pause = try await ads.format(.pause)
        #expect(pause.id == "img-p1")
        let first = harness.adsRequests[0].body
        #expect(first?["formats"] == nil, "no formats: every request is for all of them")
        #expect(first?["held"] as? [String] == [])
        let session = first?["sessionId"] as? String
        #expect(session?.isEmpty == false)

        _ = try await ads.format(.linear)
        let second = harness.adsRequests[1].body
        #expect(second?["sessionId"] as? String == session, "one session per VideoAds")
        #expect(Set(second?["held"] as? [String] ?? []) == ["img-p1", "vid-l1"], "both unshown bids are listed")
    }

    @Test func everyVideoAdsHasItsOwnSession() async throws {
        let first = await makeAds(content: "a")
        let second = harness.player.ads(for: .init(id: "b", language: "en"))
        #expect(first.sessionId != second.sessionId)
    }

    @Test func thePlayerIsTheScreenInItsOrientationAndThePlayheadIsReadAtRequestTime() async throws {
        let window = TestWindow(size: CGSize(width: 844, height: 390))
        defer { window.tearDown() }
        Environment.keyWindow = { window.window }
        let ads = await makeAds()
        harness.player.playhead = 12.5
        harness.serve(Fixtures.ad(id: "img-p2"))
        _ = try await ads.format(.pause)
        let player = harness.adsRequests.first?.body?["player"] as? [String: Any]
        #expect(player?["width"] as? Int == 844)
        #expect(player?["height"] as? Int == 390, "landscape: the screen as it is now")
        #expect(player?["fullscreen"] as? Bool == true)
        #expect(player?["playhead"] as? Int == 12_500)
    }

    @Test func theRequestCarriesConsentFromTheCMPStorageAndTheCurrentTargeting() async throws {
        Environment.consentDefaults.set("TC-STR", forKey: "IABTCF_TCString")
        let ads = await makeAds()
        KontextVideo.shared.user = KontextVideo.User(id: "someone")
        KontextVideo.shared.variantId = "b"
        harness.serve(Fixtures.ad(id: "img-p3"))
        _ = try await ads.format(.pause)
        let body = harness.adsRequests.first?.body
        #expect((body?["regulatory"] as? [String: Any])?["gdprConsent"] as? String == "TC-STR")
        #expect((body?["user"] as? [String: Any])?["id"] as? String == "someone")
        #expect(body?["variantId"] as? String == "b")
    }

    // MARK: Following the server

    @Test func aReServedAdIsTheSameObjectStillLoaded() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p4"))
        let first = try await ads.format(.pause)
        try await first.load()
        let second = try await ads.format(.pause)
        #expect(second === first, "same id: the same ad")
        #expect(second.isLoaded)
        try await second.load()
        #expect(pages.served.filter { $0 == "img-p4" }.count == 1, "nothing rendered again")
    }

    @Test func aReServedPayloadIsIgnored() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p5", expires: 3_600_000))
        let ad = try await ads.format(.pause)
        var changed = Fixtures.ad(id: "img-p5", expires: 1)
        changed["price"] = ["model": "cpm", "value": 99, "currency": "USD", "precision": "exact"]
        harness.serve(changed)
        let again = try await ads.format(.pause)
        #expect(again === ad)
        #expect(again.price.value == 7.5, "the same id holds the same payload")
        #expect(again.descriptor.isExpired == false, "and keeps its original deadline")
    }

    @Test func otherFormatsWaitForTheirOwnCall() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p6"), "overlay": Fixtures.overlayAd(id: "img-o6")])
        _ = try await ads.format(.pause)
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p6"), "overlay": Fixtures.overlayAd(id: "img-o6")])
        let overlay = try await ads.format(.overlay)
        #expect(overlay.id == "img-o6")
        #expect(Set(harness.adsRequests[1].body?["held"] as? [String] ?? []) == ["img-p6", "img-o6"])
    }

    @Test func aNewIdReplacesTheHeldBidWhateverTheSDKsClockSays() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p7"))
        let old = try await ads.format(.pause)
        try await old.load()
        harness.serve(Fixtures.ad(id: "img-p8"))
        let new = try await ads.format(.pause)
        #expect(new.id == "img-p8")
        #expect(old.invalidationReason == .expired, "the server replaces a bid only once it expired")
        #expect(throws: VideoAdError.self) { try old.show(in: harness.player.view) }
        let loadError = await error { try await old.load() }
        guard case .invalidated(.expired) = loadError else { Issue.record("expected invalidated(.expired), got \(String(describing: loadError))"); return }
        #expect(await notUsedBeacons().isEmpty, "no notice: the server replaced it, it knows")
    }

    @Test func aNoFillDropsTheHeldBidAndIsThrownWithTheReason() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p9"))
        let held = try await ads.format(.pause)
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("frequencyCap")))
        let noFill = await error { try await ads.format(.pause) }
        guard case .noFill(let reason) = noFill else { Issue.record("expected noFill"); return }
        #expect(reason == .frequencyCap)
        #expect(held.invalidationReason == .expired)
        harness.serve(Fixtures.ad(id: "img-p10"))
        #expect(try await ads.format(.pause).id == "img-p10", "the next call asks again")
        #expect(harness.adsRequests[2].body?["held"] as? [String] == [])
    }

    @Test func aFormatWithoutAConfigurationIsANoFill() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("formatNotEnabled")))
        let noFill = await error { try await ads.format(.linear) }
        guard case .noFill(let reason) = noFill else { Issue.record("expected noFill"); return }
        #expect(reason == .formatNotEnabled)
    }

    @Test func anExpiredBidIsDroppedSilentlyBeforeTheNextRequest() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p11", expires: 30_000))
        let ad = try await ads.format(.pause)
        advanceClock(by: 31)
        harness.serve(Fixtures.ad(id: "img-p12"))
        _ = try await ads.format(.pause)
        #expect(harness.adsRequests[1].body?["held"] as? [String] == [], "an expired bid is not listed")
        #expect(ad.invalidationReason == .expired)
        #expect(await notUsedBeacons().isEmpty, "no expiry notice: the server knows expires")
    }

    @Test func aReServedIdThatExpiredDuringTheRequestNeverComesBack() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p13", expires: 30_000))
        let ad = try await ads.format(.pause)
        harness.serve(Fixtures.ad(id: "img-p13"), delay: 0.3)
        let again = Task { try await ads.format(.pause) }
        await sleepMs(50)
        advanceClock(by: 31)
        let late = await error { try await again.value }
        guard case .noFill(let reason) = late else { Issue.record("expected noFill, got \(String(describing: late))"); return }
        #expect(reason == .alreadyUsed)
        #expect(ad.invalidationReason == .expired)
    }

    // MARK: Failures

    @Test func aFailedRequestReturnsTheHeldBidWhileItIsValid() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p14"))
        let held = try await ads.format(.pause)
        harness.server.on("/v2/video/ads", .failure(.timedOut))
        #expect(try await ads.format(.pause) === held)
        let nothing = await error { try await ads.format(.linear) }
        guard case .request = nothing else { Issue.record("expected request, got \(String(describing: nothing))"); return }
    }

    @Test func serverErrorsAreRequestErrorsNeverRetried() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("invalidRequest"), status: 400))
        let failure = await error { try await ads.format(.pause) }
        guard case .request = failure else { Issue.record("expected request, got \(String(describing: failure))"); return }
        #expect(harness.adsRequests.count == 1)
    }

    @Test func anEmptyIdOrLanguageStopsADebugBuildAndBadMetadataDoesNot() async {
        _ = await harness.initialize()
        var assertions: [String] = []
        Environment.assertionFailure = { assertions.append($0) }
        _ = harness.player.ads(for: .init(id: "v", language: "en", duration: .nan, episodeNumber: 0))
        #expect(assertions.isEmpty, "metadata left out is a warning, not a programmer error")
        _ = harness.player.ads(for: .init(id: "", language: "en"))
        _ = harness.player.ads(for: .init(id: "v", language: ""))
        #expect(assertions == ["KontextVideo.Content: id is empty", "KontextVideo.Content: language is empty"])
    }

    @Test func destroyWhileTheATTDialogIsUpReleasesTheWaiterAndTheDialogGoesOn() async {
        let gate = Gate()
        var prompts = 0
        Environment.trackingAuthorizationStatus = { .notDetermined }
        Environment.requestTrackingAuthorization = {
            prompts += 1
            while !gate.open { await sleepMs(5) }
            return .authorized
        }
        await WebKitWarmup.ensure()
        _ = await KontextVideo.shared.initialize(with: KontextVideo.Configuration(
            publisherToken: "test-dev", requestTrackingAuthorization: true, logLevel: .none, adServerURL: harness.server.baseURL))
        let first = harness.player.ads(for: .init(id: "v1", language: "en"))
        let second = harness.player.ads(for: .init(id: "v2", language: "en"))
        harness.serve(Fixtures.ad(id: "img-att"))
        let destroyed = Task { await error { try await first.format(.pause) } }
        let other = Task { try? await second.format(.pause) }
        #expect(await waitUntil { prompts == 1 })
        first.destroy()
        let failure = await destroyed.value
        guard case .destroyed = failure else { Issue.record("expected destroyed, got \(String(describing: failure))"); return }
        #expect(!gate.open, "released while the dialog is still up")
        gate.open = true
        #expect(await other.value?.id == "img-att", "the other video's request waited for the same dialog and went on")
        #expect(prompts == 1)
        #expect(harness.adsRequests.count == 1, "the destroyed video sent nothing")
    }

    final class Gate {
        var open = false
    }

    @Test func beforeInitializeFormatThrowsNotInitialized() async {
        Environment.assertionFailure = { _ in }
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        let failure = await error { try await ads.format(.pause) }
        guard case .notInitialized = failure else { Issue.record("expected notInitialized, got \(String(describing: failure))"); return }
        #expect(harness.adsRequests.isEmpty)
    }

    @Test func aFailedInitIsRetriedByFormatAndThrowsWhenTheRetryFails() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        let ads = await makeAds()
        let configs = harness.server.requests(to: "/v2/config").count
        let failure = await error { try await ads.format(.pause) }
        guard case .initializationFailed = failure else { Issue.record("expected initializationFailed, got \(String(describing: failure))"); return }
        #expect(harness.server.requests(to: "/v2/config").count > configs, "format() retried /config")
    }

    @Test func destroyWhileWaitingForInitThrowsDestroyed() async {
        var config = StubServer.Response.failure(.timedOut)
        config.delay = 0.2
        harness.server.on("/v2/config", config)
        let ads = await makeAds()
        let call = Task { try await ads.format(.pause) }
        await sleepMs(50)
        ads.destroy()
        let result = await call.result
        guard case .failure(VideoAdError.destroyed) = result else { Issue.record("expected destroyed, got \(result)"); return }
    }

    @Test func formatWaitsForInitInFlight() async throws {
        await WebKitWarmup.ensure()
        var config = StubServer.Response.json(Fixtures.initEnabled())
        config.delay = 0.2
        harness.server.on("/v2/config", config)
        KontextVideo.shared.initialize(with: harness.configuration, completion: nil)
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        harness.serve(Fixtures.ad(id: "img-p15"))
        #expect(try await ads.format(.pause).id == "img-p15")
    }

    // MARK: The kill switch

    @Test func aDisabledResponseSwitchesTheSDKOffAndDropsEveryBidWithoutNotices() async throws {
        let ads = await makeAds()
        let other = harness.player.ads(for: .init(id: "other", language: "en"))
        harness.serve(Fixtures.ad(id: "img-p16"))
        let loaded = try await other.format(.pause)
        try await loaded.load()
        let held = try await ads.format(.pause)
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("publisherDisabled")))
        let off = await error { try await ads.format(.linear) }
        guard case .disabled(let reason) = off else { Issue.record("expected disabled"); return }
        #expect(reason == "publisherDisabled")
        #expect(KontextVideo.shared.state == .disabled(reason: "publisherDisabled"))
        let heldLoad = await error { try await held.load() }
        guard case .disabled = heldLoad else { Issue.record("expected disabled, got \(String(describing: heldLoad))"); return }
        #expect(throws: VideoAdError.self) { try loaded.show(in: harness.player.view) }
        let otherFormat = await error { try await other.format(.overlay) }
        guard case .disabled = otherFormat else { Issue.record("expected disabled"); return }
        #expect(await notUsedBeacons().isEmpty, "no notices: the server switched the SDK off, it knows")
    }

    @Test func aKillSwitchDuringALoadMakesItThrowDisabled() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "dead-p16b"))
        let ad = try await ads.format(.pause)
        let load = Task { try await ad.load() }
        await sleepMs(100)
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("publisherDisabled")))
        _ = await error { try await ads.format(.linear) }
        do {
            _ = try await load.value
            Issue.record("expected disabled")
        } catch VideoAdError.disabled(let reason) {
            #expect(reason == "publisherDisabled")
        }
    }

    @Test func aDisabledConfigThrowsDisabled() async {
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        let ads = await makeAds()
        let failure = await error { try await ads.format(.pause) }
        guard case .disabled(let reason) = failure else { Issue.record("expected disabled"); return }
        #expect(reason == "publisherDisabled")
    }

    // MARK: The shared request and its races

    @Test func callsMadeWhileARequestRunsShareIt() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p17"), "linear": Fixtures.linearAd(id: "vid-l17")], delay: 0.15)
        async let pause = ads.format(.pause)
        async let linear = ads.format(.linear)
        let (p, l) = try await (pause, linear)
        #expect(p.id == "img-p17")
        #expect(l.id == "vid-l17")
        #expect(harness.adsRequests.count == 1, "one request for both")
    }

    @Test func sequentialCallsEachSendTheirOwnRequest() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p18"), "linear": Fixtures.linearAd(id: "vid-l18")])
        _ = try await ads.format(.pause)
        _ = try await ads.format(.linear)
        #expect(harness.adsRequests.count == 2)
    }

    @Test func cancellingACallStopsOnlyItsWaitingTheRequestContinuesForTheOthers() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p19"), "linear": Fixtures.linearAd(id: "vid-l19")], delay: 0.3)
        let pause = Task { try await ads.format(.pause) }
        let linear = Task { try await ads.format(.linear) }
        await sleepMs(50)
        let cancelledAt = Date()
        pause.cancel()
        do {
            _ = try await pause.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(cancelledAt) < 0.2, "the cancelled call stops waiting at once")
        }
        #expect(try await linear.value.id == "vid-l19", "the other call still gets its bid")
        #expect(harness.adsRequests.count == 1)
        #expect(try await ads.format(.pause).id == "img-p19", "the cancelled call's bid was kept")
    }

    @Test func aBidRejectedWhileARequestRunsIsIgnoredWhenTheResponseReServesIt() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p20"), "linear": Fixtures.linearAd(id: "vid-l20")])
        let ad = try await ads.format(.pause)
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p20"), "linear": Fixtures.linearAd(id: "vid-l20")], delay: 0.2)
        let pause = Task { try await ads.format(.pause) }
        let linear = Task { try await ads.format(.linear) }
        await sleepMs(50)
        #expect(Set(harness.adsRequests.last?.body?["held"] as? [String] ?? []) == ["img-p20", "vid-l20"], "the request listed it before the reject")
        try ad.reject()
        do {
            _ = try await pause.value
            Issue.record("expected noFill")
        } catch VideoAdError.noFill(let reason) {
            #expect(reason == .alreadyUsed, "a spent id is never accepted again")
        }
        #expect(try await linear.value.id == "vid-l20", "other formats get their bids normally")
        #expect(await notUsedBeacons(expecting: 1).map(\.adId) == ["img-p20"], "one notice, from the reject")
    }

    @Test func aBidShownWhileARequestRunsIsIgnoredWhenTheResponseReServesIt() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p21"))
        let ad = try await ads.format(.pause)
        try await ad.load()
        harness.serve(Fixtures.ad(id: "img-p21"), delay: 0.2)
        let again = Task { try await ads.format(.pause) }
        await sleepMs(50)
        try ad.show(in: harness.player.view)
        do {
            _ = try await again.value
            Issue.record("expected noFill")
        } catch VideoAdError.noFill(let reason) {
            #expect(reason == .alreadyUsed)
        }
        #expect(ad.wasShown && !ad.hasEnded, "the ad on screen is untouched")
    }

    // MARK: Destroying

    @Test func destroyEndsEverythingWithOneNoticePerHeldBid() async throws {
        let window = TestWindow()
        defer { window.tearDown() }
        window.add(harness.player.view)
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p22"), "overlay": Fixtures.overlayAd(id: "img-o22"), "linear": Fixtures.linearAd(id: "vid-l22")])
        let loaded = try await ads.format(.pause)
        try await loaded.load()
        let unloaded = try await ads.format(.linear)
        let showing = try await ads.format(.overlay)
        try await showing.load()
        let delegate = RecordingDelegate()
        showing.delegate = delegate
        try showing.show(in: harness.player.view)

        ads.destroy()
        #expect(delegate.endReasons == [.destroyed])
        #expect(Set(await notUsedBeacons(expecting: 2).map(\.adId)) == ["img-p22", "vid-l22"], "every held bid, loaded or not; not the ad on screen")
        #expect(await notUsedBeacons().allSatisfy { $0.reason == "destroyed" })
        #expect(throws: VideoAdError.self) { try loaded.show(in: harness.player.view) }
        let unloadedLoad = await error { try await unloaded.load() }
        guard case .destroyed = unloadedLoad else { Issue.record("expected destroyed"); return }
        let after = await error { try await ads.format(.pause) }
        guard case .destroyed = after else { Issue.record("expected destroyed"); return }

        ads.destroy()
        #expect(delegate.endReasons.count == 1, "destroy twice does nothing more")
        #expect(await notUsedBeacons().count == 2)
    }

    @Test func destroyDuringARequestThrowsDestroyedAndIgnoresTheLateResponse() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p23"), delay: 0.3)
        let pending = Task { try await ads.format(.pause) }
        await sleepMs(50)
        ads.destroy()
        do {
            _ = try await pending.value
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
        await sleepMs(350)
        #expect(await notUsedBeacons().isEmpty, "the late bids were never held; the server closes them at expiry")
    }

    @Test func releasingTheVideoAdsDoesWhatDestroyDoes() async throws {
        var ads: VideoAds? = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p24"))
        let ad = try await ads!.format(.pause)
        try await ad.load()
        ads = nil
        #expect(ad.invalidationReason == .destroyed)
        #expect(ad.isReady == false)
        #expect(await notUsedBeacons(expecting: 1).map(\.reason) == ["destroyed"])
    }

    // MARK: Playhead

    @Test func playheadComesFromTheProviderOrTheTrackedPlayerOrIsZero() async {
        let ads = await makeAds()
        harness.player.playhead = 47
        #expect(ads.playhead == 47)
        ads.playheadProvider = { .nan }
        #expect(ads.playhead == 0, "never NaN")
        ads.playheadProvider = { -3 }
        #expect(ads.playhead == 0, "never negative")
        ads.playheadProvider = { .infinity }
        #expect(ads.playhead == 0, "never infinite")
        ads.playheadProvider = { .greatestFiniteMagnitude }
        #expect(ads.playhead == 315_360_000, "a huge value is clamped, not a crash")
        let player = AVPlayer()
        ads.trackPlayhead(of: player)
        #expect(ads.playhead == 0, "tracking a player replaces the provider; no item: 0")
        ads.playheadProvider = { 5 }
        #expect(ads.playhead == 5, "a provider replaces the tracked player")
        let bare = VideoAds(content: .init(id: "bare", language: "en"))
        #expect(bare.playhead == 0, "nothing set: the start of the video, what a prefetch sends")
    }

    @Test func aTrackedPlayerIsHeldWeakly() async {
        let ads = await makeAds()
        var player: AVPlayer? = AVPlayer()
        ads.trackPlayhead(of: player!)
        player = nil
        #expect(ads.playhead == 0)
    }
}
}
