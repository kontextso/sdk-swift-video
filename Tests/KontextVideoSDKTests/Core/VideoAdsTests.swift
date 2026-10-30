import AVFoundation
import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

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

    @Test func labelsGoWithEveryRequest() async throws {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-l", language: "en"), labels: ["stage": "first_episode", "layout": "inline"])
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-l1")])
        _ = try await ads.format(.pause)
        _ = try await ads.format(.pause)
        #expect(harness.adsRequests.map { $0.body?["labels"] as? [String: String] } == Array(repeating: ["stage": "first_episode", "layout": "inline"], count: 2))
        let bare = harness.player.ads(for: .init(id: "ep-n", language: "en"))
        _ = try await bare.format(.pause)
        #expect(harness.adsRequests[2].body?["labels"] == nil, "none: left out")
    }

    @Test func labelsThatBreakTheRulesAreDroppedWithAWarning() async throws {
        _ = await harness.initialize()
        Logger.level = .warning
        defer { Logger.level = .warning }
        var warnings: [String] = []
        Logger.sink = { level, message in if level == .warning, message.contains("labels of video") { warnings.append(message) } }
        var labels = ["stage": "unlock", "Stage": "x", "bad-key": "x", "empty": "", "long": String(repeating: "é", count: 33)]
        for index in 0..<25 { labels["k\(index)"] = "v" }   // 26 valid keys with "stage": 20 are kept
        let ads = VideoAds(content: .init(id: "ep-d", language: "en"), labels: labels)
        #expect(ads.labels.count == Labels.maxCount)
        #expect(ads.labels["Stage"] == nil && ads.labels["bad-key"] == nil && ads.labels["empty"] == nil)
        #expect(ads.labels["long"] == nil, "66 bytes: dropped, not cut")
        #expect(warnings.count == 1, "one warning names them all")
        #expect(warnings.first?.contains("bad-key") == true && warnings.first?.contains("more than 20") == true)
        #expect(Labels.isValidKey(String(repeating: "a", count: 64)) && !Labels.isValidKey(String(repeating: "a", count: 65)))
        harness.serve(formats: ["linear": Fixtures.linearAd(id: "vid-d1")])
        _ = try await ads.format(.linear)
        #expect(harness.adsRequests[0].body?["labels"] as? [String: String] == ads.labels, "what the property holds is what goes")
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
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(Fixtures.ad(id: "img-p13"), gate: gate)
        let again = Task { try await ads.format(.pause) }
        #expect(await waitUntil { self.harness.adsRequests.count == 2 })
        advanceClock(by: 31)
        gate.open()
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

    @Test func aFailedRequestLeavesNothingBehindAndTheNextCallSendsAFreshOne() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .failure(.timedOut))
        let failure = await error { try await ads.format(.pause) }
        guard case .request = failure else { Issue.record("expected request, got \(String(describing: failure))"); return }
        harness.serve(Fixtures.ad(id: "img-after-failure"))
        #expect(try await ads.format(.pause).id == "img-after-failure", "the failed request is not reused")
        #expect(harness.adsRequests.count == 2)
        #expect(harness.adsRequests[1].body?["held"] as? [String] == [])
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
        let gate = DialogGate()
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

    /// Holds the ATT dialog up until the test opens it; `StubServer.Gate` holds a server response.
    final class DialogGate {
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

    @Test func destroyWhileWaitingForInitThrowsDestroyedAtOnceAndTheOthersShareOneConfig() async throws {
        await WebKitWarmup.ensure()
        let gate = StubServer.Gate()
        // A safety net: without the fix the destroyed call would hang until /config answers.
        Task { await sleepMs(3000); gate.open() }
        var config = StubServer.Response.json(Fixtures.initEnabled())
        config.gate = gate
        harness.server.on("/v2/config", config)
        KontextVideo.shared.initialize(with: harness.configuration, completion: nil)
        let destroyed = harness.player.ads(for: .init(id: "v1", language: "en"))
        let other = harness.player.ads(for: .init(id: "v2", language: "en"))
        harness.serve(Fixtures.ad(id: "img-init"))
        let call = Task { try await destroyed.format(.pause) }
        let otherCall = Task { try await other.format(.pause) }
        await sleepMs(20)
        destroyed.destroy()
        let result = await call.result
        guard case .failure(VideoAdError.destroyed) = result else { Issue.record("expected destroyed, got \(result)"); return }
        #expect(!gate.isOpen, "it finished while /config was still out")
        gate.open()
        #expect(try await otherCall.value.id == "img-init", "the other video still waits for /config and gets its ad")
        #expect(harness.server.requests(to: "/v2/config").count == 1)
        #expect(harness.adsRequests.count == 1, "the destroyed video sent nothing")
    }

    @Test func formatWaitsForInitInFlight() async throws {
        await WebKitWarmup.ensure()
        let gate = StubServer.Gate()
        defer { gate.open() }
        var config = StubServer.Response.json(Fixtures.initEnabled())
        config.gate = gate
        harness.server.on("/v2/config", config)
        KontextVideo.shared.initialize(with: harness.configuration, completion: nil)
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        harness.serve(Fixtures.ad(id: "img-p15"))
        let call = Task { try await ads.format(.pause) }
        await sleepMs(20)
        #expect(harness.adsRequests.isEmpty, "nothing leaves before /config answers")
        gate.open()
        #expect(try await call.value.id == "img-p15")
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

    @Test func switchedOffDuringTheATTDialogNothingLeaves() async {
        let gate = DialogGate()
        Environment.trackingAuthorizationStatus = { .notDetermined }
        Environment.requestTrackingAuthorization = {
            while !gate.open { await sleepMs(5) }
            return .authorized
        }
        await WebKitWarmup.ensure()
        _ = await KontextVideo.shared.initialize(with: KontextVideo.Configuration(
            publisherToken: "test-dev", requestTrackingAuthorization: true, logLevel: .none, adServerURL: harness.server.baseURL))
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        harness.serve(Fixtures.ad(id: "img-att-off"))
        let call = Task { await error { try await ads.format(.pause) } }
        await sleepMs(30)
        // Another video's response switches the SDK off while this one's dialog is up.
        KontextVideo.shared.disable(reason: "publisherDisabled")
        gate.open = true
        let failure = await call.value
        guard case .disabled(let reason) = failure else { Issue.record("expected disabled, got \(String(describing: failure))"); return }
        #expect(reason == "publisherDisabled")
        #expect(harness.adsRequests.isEmpty, "no request after the kill switch")
    }

    @Test func switchedOffWhileTheResponseWasOutItsAdsAreNeverHeld() async throws {
        let ads = await makeAds()
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(Fixtures.ad(id: "img-late"), gate: gate)
        let call = Task { await error { try await ads.format(.pause) } }
        #expect(await waitUntil { self.harness.adsRequests.count == 1 })
        KontextVideo.shared.disable(reason: "publisherDisabled")
        gate.open()
        let failure = await call.value
        guard case .disabled(let reason) = failure else { Issue.record("expected disabled, got \(String(describing: failure))"); return }
        #expect(reason == "publisherDisabled")
        ads.destroy()
        #expect(await notUsedBeacons().isEmpty, "the late ad was never held: destroy has nothing to notify")
    }

    @Test func switchedOffWhileAFailingRequestWasOutTheHeldAdDoesNotComeBack() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-held-off"))
        _ = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        var failing = StubServer.Response.failure(.timedOut)
        failing.gate = gate
        harness.server.on("/v2/video/ads", failing)
        let call = Task { await error { try await ads.format(.pause) } }
        #expect(await waitUntil { self.harness.adsRequests.count == 2 })
        KontextVideo.shared.disable(reason: "publisherDisabled")
        gate.open()
        let failure = await call.value
        guard case .disabled(let reason) = failure else { Issue.record("expected disabled, not the held ad, got \(String(describing: failure))"); return }
        #expect(reason == "publisherDisabled")
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
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p17"), "linear": Fixtures.linearAd(id: "vid-l17")], gate: gate)
        let pause = Task { try await ads.format(.pause) }
        let linear = Task { try await ads.format(.linear) }
        #expect(await waitUntil { self.harness.adsRequests.count == 1 })
        await sleepMs(20)
        gate.open()
        let (p, l) = try await (pause.value, linear.value)
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
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p19"), "linear": Fixtures.linearAd(id: "vid-l19")], gate: gate)
        let pause = Task { try await ads.format(.pause) }
        var linearDone = false
        let linear = Task { () throws -> VideoAd in
            defer { linearDone = true }
            return try await ads.format(.linear)
        }
        #expect(await waitUntil(5) { self.harness.adsRequests.count == 1 })
        pause.cancel()
        do {
            _ = try await pause.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            #expect(!linearDone, "the cancelled call stopped while the request was still out")
        }
        gate.open()
        #expect(try await linear.value.id == "vid-l19", "the other call still gets its bid")
        #expect(harness.adsRequests.count == 1)
        #expect(try await ads.format(.pause).id == "img-p19", "the cancelled call's bid was kept")
    }

    @Test func aBidRejectedWhileARequestRunsIsIgnoredWhenTheResponseReServesIt() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p20"), "linear": Fixtures.linearAd(id: "vid-l20")])
        let ad = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-p20"), "linear": Fixtures.linearAd(id: "vid-l20")], gate: gate)
        let pause = Task { try await ads.format(.pause) }
        let linear = Task { try await ads.format(.linear) }
        #expect(await waitUntil { self.harness.adsRequests.count == 2 })
        #expect(Set(harness.adsRequests.last?.body?["held"] as? [String] ?? []) == ["img-p20", "vid-l20"], "the request listed it before the reject")
        try ad.reject()
        gate.open()
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
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(Fixtures.ad(id: "img-p21"), gate: gate)
        let again = Task { try await ads.format(.pause) }
        #expect(await waitUntil { self.harness.adsRequests.count == 2 })
        try ad.show(in: harness.player.view)
        gate.open()
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

    @Test func destroyNotifiesValidHeldAdsOnlyAnExpiredOneLeavesSilently() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-d-old", expires: 30_000), "overlay": Fixtures.overlayAd(id: "img-d-new")])
        let old = try await ads.format(.pause)
        let fresh = try await ads.format(.overlay)
        advanceClock(by: 31)   // the pause ad expired and nothing called the SDK since
        ads.destroy()
        #expect(old.invalidationReason == .expired && fresh.invalidationReason == .destroyed)
        #expect(await notUsedBeacons(expecting: 1).map(\.adId) == ["img-d-new"], "one notice, for the valid ad")
        #expect(await notUsedBeacons().count == 1, "none for the expired one: the server knows expires")
    }

    @Test func destroyDuringARequestThrowsDestroyedAndIgnoresTheLateResponse() async throws {
        let ads = await makeAds()
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(Fixtures.ad(id: "img-p23"), gate: gate)
        let pending = Task { try await ads.format(.pause) }
        #expect(await waitUntil { self.harness.adsRequests.count == 1 })
        ads.destroy()
        do {
            _ = try await pending.value
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
        gate.open()
        #expect(await notUsedBeacons().isEmpty, "the late bids were never held; the server closes them at expiry")
    }

    @Test func releasingAVideoAdsThatStillHoldsAdsWarnsOnTheConsole() async throws {
        var ads: VideoAds? = await makeAds()
        Logger.level = .warning
        defer { Logger.level = .warning }
        var warnings: [String] = []
        Logger.sink = { level, message in if level == .warning, message.contains("released while holding") { warnings.append(message) } }
        harness.serve(Fixtures.ad(id: "img-rel-w"))
        let ad = try await ads!.format(.pause)
        ads = nil   // the app kept the ad, not its VideoAds
        #expect(ad.invalidationReason == .destroyed)
        #expect(warnings.count == 1, "one warning: \(warnings)")
        let destroyed = harness.player.ads(for: .init(id: "ep-2", language: "en"))
        harness.serve(Fixtures.ad(id: "img-rel-d"))
        _ = try await destroyed.format(.pause)
        destroyed.destroy()   // destroyed first, then released: nothing held, nothing to say
        await sleepMs(20)
        #expect(warnings.count == 1)
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

    @Test func releasingTheVideoAdsMidRequestFreesItTheRequestDoesNotKeepItAlive() async throws {
        var ads: VideoAds? = await makeAds()
        weak var released: VideoAds?
        released = ads
        let gate = StubServer.Gate()
        defer { gate.open() }
        harness.serve(Fixtures.ad(id: "img-released"), gate: gate)
        let call = Task { [ads] in _ = try? await ads?.format(.pause) }
        #expect(await waitUntil { self.harness.adsRequests.count == 1 })
        // The caller stops waiting; the app drops its reference while the response is still out.
        call.cancel()
        await call.value
        ads = nil
        #expect(await waitUntil { released == nil }, "released while the request was out: its deinit cancels the request")
        #expect(!gate.isOpen)
    }

    @Test func destroyWhileTheUserAgentIsLookedUpThrowsDestroyedAtOnceAndTheOthersWait() async throws {
        let gate = DialogGate()
        var lookups = 0
        Environment.userAgent = {
            lookups += 1
            while !gate.open { await sleepMs(5) }
            return "Mozilla/5.0 test"
        }
        // A safety net: without the fix the destroyed call would wait until the lookup answers.
        Task { await sleepMs(3000); gate.open = true }
        let destroyed = await makeAds(content: "v1")
        let other = harness.player.ads(for: .init(id: "v2", language: "en"))
        harness.serve(Fixtures.ad(id: "img-ua"))
        let call = Task { await error { try await destroyed.format(.pause) } }
        let otherCall = Task { try await other.format(.pause) }
        #expect(await waitUntil { lookups == 1 })
        await sleepMs(20)
        destroyed.destroy()
        let failure = await call.value
        guard case .destroyed = failure else { Issue.record("expected destroyed, got \(String(describing: failure))"); return }
        #expect(!gate.open, "released while the user agent was still being looked up")
        gate.open = true
        #expect(try await otherCall.value.id == "img-ua", "the other video waited for the same lookup")
        #expect(lookups == 1, "one lookup for everyone, the one the enabled /config started")
        #expect(harness.adsRequests.count == 1, "the destroyed video sent nothing")
        #expect(harness.adsRequests.first?.body.flatMap { ($0["device"] as? [String: Any])?["network"] as? [String: Any] }?["userAgent"] as? String == "Mozilla/5.0 test")
    }

    @Test func destroyReleasesThePlayheadProvider() async {
        final class Screen {
            var ads: VideoAds?
            func playhead() -> TimeInterval { 12 }
        }
        var screen: Screen? = Screen()
        weak var released: Screen?
        released = screen
        let ads = await makeAds()
        screen?.ads = ads
        ads.usePlayhead { [screen] in screen?.playhead() ?? 0 }   // a strong capture, the cycle an app writes
        #expect(ads.playhead == 12)
        ads.destroy()
        screen = nil
        #expect(released == nil, "destroy dropped the reads that kept the app's object")
        #expect(ads.playhead == 0 && !ads.playback.isTracking)
    }

    @Test func aMemoryWarningReleasesExpiredCreativesAndKeepsValidOnes() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-mw-old", expires: 30_000), "overlay": Fixtures.overlayAd(id: "img-mw-new")])
        let old = try await ads.format(.pause)
        let fresh = try await ads.format(.overlay)
        try await old.load()
        try await fresh.load()
        advanceClock(by: 31)   // the pause ad's 30 s ran out, the overlay's hour did not
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(old.invalidationReason == .expired && old.loadedBridge == nil, "the expired creative is released at once")
        #expect(fresh.isReady && fresh.loadedBridge != nil, "a valid loaded ad stays loaded, so show stays instant")
        #expect(await notUsedBeacons().isEmpty, "silently: the server knows expires")
    }

    // MARK: Playhead

    @Test func playheadComesFromTheTrackedPlayerOrIsZero() async {
        let ads = await makeAds()
        harness.player.playhead = 47
        #expect(ads.playhead == 47)
        ads.usePlayhead { .nan }
        #expect(ads.playhead == 0, "never NaN")
        ads.usePlayhead { -3 }
        #expect(ads.playhead == 0, "never negative")
        ads.usePlayhead { .infinity }
        #expect(ads.playhead == 0, "never infinite")
        ads.usePlayhead { .greatestFiniteMagnitude }
        #expect(ads.playhead == 315_360_000, "a huge value is clamped, not a crash")
        let player = AVPlayer()
        ads.track(player)
        #expect(ads.playhead == 0, "tracking a player replaces what was tracked; no item: 0")
        ads.usePlayhead { 5 }
        #expect(ads.playhead == 5, "and the other way round")
        let bare = VideoAds(content: .init(id: "bare", language: "en"))
        #expect(bare.playhead == 0, "nothing set: the start of the video, what a prefetch sends")
    }

    @Test func aTrackedPlayerIsHeldWeakly() async {
        let ads = await makeAds()
        var player: AVPlayer? = AVPlayer()
        weak var released: AVPlayer?
        released = player
        ads.track(player!)
        player = nil
        #expect(released == nil, "tracking does not keep the player")
        #expect(ads.playhead == 0 && !ads.playback.isTracking)
    }
}
}
