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
    /// URLSession); then, as for none, until no beacon is still on its way (`beaconsSettled`), however slow.
    private func notUsedBeacons(expecting count: Int = 0) async -> [(bidId: String, reason: String?)] {
        let arrived = { self.harness.server.beacons.filter { $0.event == "notUsed" }.map { ($0.bidId, $0.query["reason"]) } }
        if count > 0 { _ = await waitUntil { arrived().count >= count } }
        await beaconsSettled()
        return arrived()
    }

    // MARK: A malformed ad

    @Test func oneMalformedAdIsANoFillForItsFormatOnlyAndIsReportedOnce() async throws {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportErrors: true)))
        let ads = await makeAds()
        var linear = Fixtures.linearAd(id: "vid-bad")
        linear["price"] = ["value": 2.0, "currency": "usd", "precision": "exact"]
        harness.serve(formats: ["overlay": Fixtures.overlayAd(id: "img-o-good"), "linear": linear])
        async let overlay = ads.format(.overlay)
        async let missing = error { try await ads.format(.linear) }
        #expect(try await overlay.id == "img-o-good", "the other formats keep their ads")
        guard case .noFill(let reason)? = await missing else { Issue.record("expected noFill"); return }
        #expect(reason == .unknown)
        #expect(harness.adsRequests.count == 1)
        let reports = { self.harness.server.requests(to: "/v2/error").flatMap { ($0.body?["errors"] as? [[String: Any]]) ?? [] } }
        #expect(await waitUntil { !reports().isEmpty })
        await sleepMs(100)
        let report = try #require(reports().first)
        #expect(reports().count == 1, "once per request, not per caller")
        #expect(report["code"] as? String == "ads.decode_failed" && report["detail"] as? String == "linear:price.currency")
        #expect(report["requestId"] as? String == ads.lastRequestID)
    }

    @Test func anAnswerWithOneAdIdUnderTwoFormatsIsMalformedAndTheHeldAdComesBack() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p-held"))
        let held = try await ads.format(.pause)
        for order in [["overlay", "pause"], ["pause", "overlay"]] {
            harness.server.on("/v2/video/ads") { _ in
                .json(["enabled": true, "formats": order.map { format -> [String: Any] in
                    format == "overlay" ? Fixtures.filledEntry(Fixtures.overlayAd(id: "img-dup")) : Fixtures.filledEntry(Fixtures.ad(id: "img-dup"))
                }])
            }
            let error = await error { try await ads.format(.overlay) }
            #expect(error == .request(.badResponse), "\(order): a malformed answer")
            #expect(try await ads.format(.pause) === held, "\(order): the held ad comes back")
        }
    }

    @Test func anIdHeldUnderAnotherFormatMakesTheAnswerMalformedAndTheHeldAdStays() async throws {
        let ads = await makeAds()
        for (heldFormat, askedFormat) in [(AdFormat.overlay, AdFormat.pause), (.pause, .overlay)] {
            let id = "img-x-\(heldFormat.rawValue)"
            let entry = { (format: AdFormat) in Fixtures.filledEntry(format == .overlay ? Fixtures.overlayAd(id: id) : Fixtures.ad(id: id)) }
            harness.server.on("/v2/video/ads") { _ in .json(["enabled": true, "formats": [entry(heldFormat)]]) }
            let held = try await ads.format(heldFormat)
            // The next answer leaves the held format out (so its ad is kept) and brings the same id under the other.
            harness.server.on("/v2/video/ads") { _ in .json(["enabled": true, "formats": [entry(askedFormat)]]) }
            let failure = await error { try await ads.format(askedFormat) }
            #expect(failure == .request(.badResponse), "\(heldFormat): a malformed answer")
            #expect(held.invalidationReason == nil, "\(heldFormat): the held ad stays")
            #expect(try await ads.format(heldFormat) === held, "\(heldFormat): a malformed answer, the held ad comes back")
            held.reject()
            // One bid, rejected once: nothing of it is left, under either format.
            harness.server.on("/v2/video/ads") { _ in .json(["enabled": true, "formats": [entry(askedFormat)]]) }
            guard case .noFill(let reason)? = await error({ try await ads.format(askedFormat) }) else { Issue.record("\(heldFormat): expected noFill"); continue }
            #expect(reason == .alreadyUsed, "\(heldFormat)")
        }
    }

    @Test func aFormatTheAnswerLeavesOutKeepsItsHeldAdAndOnlyANoFillDropsIt() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p-kept"))
        let pause = try await ads.format(.pause)
        try await pause.load()
        // An answer with only an overlay entry: nothing said about pause.
        harness.server.on("/v2/video/ads") { _ in .json(["enabled": true, "formats": [Fixtures.filledEntry(Fixtures.overlayAd(id: "img-o-new"))]]) }
        #expect(try await ads.format(.overlay).id == "img-o-new")
        #expect(pause.isReady && pause.invalidationReason == nil, "the held pause ad stays as it is, loaded")
        #expect(try await ads.format(.pause) === pause)
        // Nothing held and nothing said: a no-fill, reason unknown.
        guard case .noFill(let reason)? = await error({ try await ads.format(.linear) }) else { Issue.record("expected noFill"); return }
        #expect(reason == .unknown)
        #expect((harness.adsRequests.last?.body?["held"] as? [String])?.contains("img-p-kept") == true, "still listed in held")
        // An explicit no-fill for pause drops it, as before.
        harness.server.on("/v2/video/ads") { _ in .json(Fixtures.noFill()) }
        _ = await error { try await ads.format(.pause) }
        #expect(pause.invalidationReason == .expired && !pause.isReady)
    }

    // MARK: The request

    @Test func privacyFieldsAreReadAfterEveryWaitOfTheRequest() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p-late"))
        KontextVideo.shared.user = KontextVideo.User(id: "before")
        KontextVideo.shared.regulatory = nil
        Environment.trackingAuthorizationStatus = { .denied }
        // The user agent lookup, one of the request's waits, held until the test lets it go.
        var asked = false
        var released = false
        UserAgent.lookup = nil
        Environment.userAgent = {
            asked = true
            while !released { await sleepMs(5) }
            return "Mozilla/5.0 (test)"
        }
        let call = Task { try await ads.format(.pause) }
        #expect(await waitUntil { asked })
        // Meanwhile: a new user, a consent update from the CMP, the app's own regulatory change, ATT authorized.
        KontextVideo.shared.user = KontextVideo.User(id: "after")
        // `false`, not `true`: a COPPA request would leave the ids out, and the late ids are what is checked.
        KontextVideo.shared.regulatory = KontextVideo.Regulatory(coppa: false)
        Environment.consentDefaults.set(1, forKey: "IABTCF_gdprApplies")
        Environment.consentDefaults.set("TC-AFTER", forKey: "IABTCF_TCString")
        let idfa = UUID()
        Environment.trackingAuthorizationStatus = { .authorized }
        Environment.advertisingIdentifier = { idfa }
        released = true
        _ = try await call.value
        let body = try #require(harness.adsRequests.first?.body)
        #expect((body["user"] as? [String: Any])?["id"] as? String == "after")
        let regulatory = body["regulatory"] as? [String: Any]
        #expect(regulatory?["coppa"] as? Bool == false && regulatory?["gdprConsent"] as? String == "TC-AFTER")
        #expect(body["attStatus"] as? String == "authorized" && (body["ifa"] as? [String: Any])?["id"] as? String == idfa.uuidString)
        KontextVideo.shared.user = nil
        KontextVideo.shared.regulatory = nil
    }

    @Test func aSlowUserAgentLookupSendsTheRequestWithTheFallbackAndTheNextOneWithTheRealOne() async throws {
        // A cold device: the WebView's user agent takes far longer than the request may wait.
        UserAgent.userAgentWait = 0.05
        var lookups = 0
        var release: CheckedContinuation<Void, Never>?
        Environment.userAgent = {
            lookups += 1
            await withCheckedContinuation { release = $0 }
            return "Mozilla/5.0 (real)"
        }
        let ads = await makeAds()   // the enabled /config starts the lookup
        let userAgent = { (index: Int) in
            ((self.harness.adsRequests[index].body?["device"] as? [String: Any])?["network"] as? [String: Any])?["userAgent"] as? String
        }
        harness.serve(Fixtures.ad(id: "img-ua-1"))
        _ = try await ads.format(.pause)
        #expect(release != nil, "the lookup is still out")
        #expect(userAgent(0) == UserAgent.fallbackUserAgent, "sent without waiting for it: \(userAgent(0) ?? "nil")")
        #expect(userAgent(0)?.hasPrefix("Mozilla/5.0 (") == true && userAgent(0)?.contains(UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")) == true)
        // The lookup goes on; the next request carries its answer (waiting as long as it takes, here).
        UserAgent.userAgentWait = 60
        harness.serve(Fixtures.ad(id: "img-ua-2"))
        let second = Task { try await ads.format(.pause) }
        release?.resume()
        _ = try await second.value
        #expect(userAgent(1) == "Mozilla/5.0 (real)")
        #expect(lookups == 1, "one lookup, not restarted by the request that gave up on it")
    }

    @Test func anAdRejectedWhileTheUserAgentIsLookedUpIsNotSentAsHeld() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-ua-held"))
        let held = try await ads.format(.pause)
        UserAgent.userAgentWait = 60
        UserAgent.lookup = nil
        var release: CheckedContinuation<Void, Never>?
        Environment.userAgent = {
            await withCheckedContinuation { release = $0 }
            return "Mozilla/5.0 (test)"
        }
        var playhead: TimeInterval = 1
        ads.usePlayhead { playhead }
        harness.serve(Fixtures.ad(id: "img-ua-next"))
        let call = Task { try await ads.format(.pause) }
        #expect(await waitUntil { release != nil }, "the lookup is out")
        held.reject()
        playhead = 7
        release?.resume()
        _ = try await call.value
        let body = try #require(harness.adsRequests.last?.body)
        #expect(body["held"] as? [String] == [], "rejected during the wait: not held")
        #expect((body["player"] as? [String: Any])?["playhead"] as? Int == 7000, "the playhead after the wait")
    }

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

    @Test func labelsAreSentExactlyAsGivenWithoutChecks() async throws {
        _ = await harness.initialize()
        Logger.level = .warning
        defer { Logger.level = .warning }
        var warnings: [String] = []
        Logger.sink = { level, message in if level == .warning { warnings.append(message) } }
        // A free format on purpose: any key, any value, any number of them.
        var labels = ["stage": "unlock", "my-ad": "x", "Player Layout": String(repeating: "é", count: 80), "empty": ""]
        for index in 1...25 { labels["k\(index)"] = "v" }
        let ads = VideoAds(content: .init(id: "ep-d", language: "en"), labels: labels)
        #expect(ads.labels == labels)
        #expect(!warnings.contains { $0.contains("label") }, "no warning: \(warnings)")
        harness.serve(formats: ["linear": Fixtures.linearAd(id: "vid-d1")])
        _ = try await ads.format(.linear)
        #expect(harness.adsRequests[0].body?["labels"] as? [String: String] == labels, "what the app gave is what goes")
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
        KontextVideo.shared.variantID = "b"
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

    /// One request answers every format: a format the app never asks for is not an error in its log.
    @Test func anUnaskedFormatNotEnabledIsQuietAndAnAskedOneWarnsOnce() async throws {
        let ads = await makeAds()
        Logger.level = .debug
        defer { Logger.level = .warning; Logger.sink = nil }
        var logged: [(level: KontextVideo.Configuration.LogLevel, message: String)] = []
        Logger.sink = { level, message in logged.append((level, message)) }
        harness.server.on("/v2/video/ads", .json(["enabled": true, "formats": [
            Fixtures.filledEntry(Fixtures.ad(id: "img-p-ne")), Fixtures.noFillEntry("formatNotEnabled", format: "overlay"),
        ]]))
        _ = try await ads.format(.pause)
        // Only this message: the simulator's tracking prompt warns on its own.
        let loud = { logged.filter { ($0.level == .error || $0.level == .warning) && $0.message.contains("no configuration") } }
        #expect(loud().isEmpty, "no warning or error at fetch: \(logged)")
        #expect(logged.contains { $0.level == .info && $0.message.contains("overlay for ep-1: no configuration") }, "logged quietly at fetch")
        logged.removeAll()
        guard case .noFill(let reason)? = await error({ try await ads.format(.overlay) }) else { Issue.record("expected noFill"); return }
        #expect(reason == .formatNotEnabled)
        #expect(loud().map(\.level) == [.warning])
        #expect(loud().first?.message == "overlay for ep-1: no configuration for this format in the Kontext dashboard (formatNotEnabled)")
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

    @Test func aHeldAdThatExpiredDuringTheRequestLeavesWithAnAnswerThatOmitsItsFormat() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-e1", expires: 30_000))
        let ad = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        // The answer says nothing about pause: only a linear ad.
        harness.server.on("/v2/video/ads") { _ in
            var response = StubServer.Response.json(["enabled": true, "formats": [Fixtures.filledEntry(Fixtures.linearAd(id: "vid-e1"))]])
            response.gate = gate
            return response
        }
        let pause = Task { try await ads.format(.pause) }
        let linear = Task { try await ads.format(.linear) }
        #expect(await waitUntil { self.harness.adsRequests.count == 2 })
        #expect(harness.adsRequests[1].body?["held"] as? [String] == ["img-e1"], "valid when the request left: held")
        advanceClock(by: 31)
        gate.open()
        #expect(try await linear.value.id == "vid-e1")
        let late = await error { try await pause.value }
        guard case .noFill(let reason) = late else { Issue.record("expected noFill, got \(String(describing: late))"); return }
        #expect(reason == .unknown)
        #expect(ad.invalidationReason == .expired, "the answer left pause out, and the ad expired meanwhile: it leaves")
        #expect(await notUsedBeacons().isEmpty, "silently: the server knows expires")
    }

    @Test func anAdThatExpiresBeforeItsWaiterResumesIsNotReturned() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-e2", expires: 30_000))
        let ad = try await ads.format(.pause)
        harness.server.on("/v2/video/ads") { _ in .json(["enabled": true, "formats": [Fixtures.filledEntry(Fixtures.linearAd(id: "vid-e2"))]]) }
        // The clock passes the pause ad's expiry after the answer swept the expired ads, before the waiter resumes.
        Logger.level = .info
        defer { Logger.level = .warning }
        Logger.sink = { _, message in if message.contains("linear for ep-1: ad vid-e2") { advanceClock(by: 31) } }
        let late = await error { try await ads.format(.pause) }
        guard case .noFill(let reason) = late else { Issue.record("expected noFill, got \(String(describing: late))"); return }
        #expect(reason == .unknown, "no ad expired at the answer: the reason is unknown")
        #expect(ad.invalidationReason == .expired)
        #expect(await notUsedBeacons().isEmpty)
    }

    // MARK: Failures

    @Test func aFailedRequestReturnsTheHeldBidWhileItIsValid() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p14"))
        let held = try await ads.format(.pause)
        harness.server.on("/v2/video/ads", .failure(.timedOut))
        #expect(try await ads.format(.pause) === held)
        let nothing = await error { try await ads.format(.linear) }
        #expect(nothing == .request(.timedOut))
    }

    @Test func aFailedRequestLeavesNothingBehindAndTheNextCallSendsAFreshOne() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .failure(.timedOut))
        let failure = await error { try await ads.format(.pause) }
        #expect(failure == .request(.timedOut))
        harness.serve(Fixtures.ad(id: "img-after-failure"))
        #expect(try await ads.format(.pause).id == "img-after-failure", "the failed request is not reused")
        #expect(harness.adsRequests.count == 2)
        #expect(harness.adsRequests[1].body?["held"] as? [String] == [])
    }

    @Test func serverErrorsAreRequestErrorsNeverRetried() async {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("invalidRequest"), status: 400))
        let failure = await error { try await ads.format(.pause) }
        #expect(failure == .request(.server(status: 400)))
        #expect(harness.adsRequests.count == 1)
    }

    /// What the app reads from a failed `format(_:)`, end to end: each kind of failure as its reason.
    @Test func aFailedRequestSaysWhy() async {
        let ads = await makeAds()
        let failures: [(StubServer.Response, VideoAdError.RequestFailure)] = [
            (.failure(.notConnectedToInternet), .offline),
            (.failure(.networkConnectionLost), .offline),
            (.failure(.cannotFindHost), .offline),
            (.failure(.timedOut), .timedOut),
            (.empty(503), .server(status: 503)),
            (.json(Fixtures.errors("invalidRequest"), status: 422), .server(status: 422)),
            (.json([1, 2]), .badResponse),
            (StubServer.Response(status: 200, body: Data("<html></html>".utf8)), .badResponse),
        ]
        for (response, reason) in failures {
            harness.server.on("/v2/video/ads", response)
            let failure = await error { try await ads.format(.pause) }
            #expect(failure == .request(reason), "\(reason)")
        }
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

    @Test func aKillSwitchFromAnotherVideoEndsThisVideosLoadAtOnce() async throws {
        let ads = await makeAds()
        let other = harness.player.ads(for: .init(id: "other-video", language: "en"))
        harness.serve(Fixtures.ad(id: "dead-p16c"))   // a page that never reports ad.loaded
        let ad = try await ads.format(.pause)
        let load = Task { await error { try await ad.load() } }
        await sleepMs(100)
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("publisherDisabled")))
        _ = await error { try await other.format(.linear) }   // another video's answer switches the SDK off
        let failure = await load.value
        guard case .disabled(let reason)? = failure else { Issue.record("expected disabled, got \(String(describing: failure))"); return }
        #expect(reason == "publisherDisabled")
        #expect(ad.invalidationReason == .destroyed, "ended without waiting for its page")
    }

    @Test func switchedOffDuringTheATTDialogNothingLeaves() async {
        let gate = DialogGate()
        Environment.trackingAuthorizationStatus = { .notDetermined }
        Environment.requestTrackingAuthorization = {
            while !gate.open { await sleepMs(5) }
            return .authorized
        }
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

    @Test func aKillSwitchInTheAnswerToADestroyedVideoAdsStillSwitchesTheSDKOff() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("killed")))
        // The app destroys the VideoAds as the answer is back, before the request reads it (a destroy earlier
        // cancels the POST, and nothing arrives).
        Environment.adsAnswerArrived = { ads.destroy() }
        let failure = await error { try await ads.format(.pause) }
        #expect(failure == .destroyed, "the caller's VideoAds is gone: \(String(describing: failure))")
        #expect(await waitUntil { KontextVideo.shared.state == .disabled(reason: "killed") }, "the answer still switches the SDK off")
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
        #expect(await waitUntil { self.harness.adsRequests.count == 1 })
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
        ad.reject()
        gate.open()
        do {
            _ = try await pause.value
            Issue.record("expected noFill")
        } catch VideoAdError.noFill(let reason) {
            #expect(reason == .alreadyUsed, "a spent id is never accepted again")
        }
        #expect(try await linear.value.id == "vid-l20", "other formats get their bids normally")
        #expect(await notUsedBeacons(expecting: 1).map(\.bidId) == ["img-p20"], "one notice, from the reject")
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
        #expect(loaded.invalidationReason == .destroyed && unloaded.invalidationReason == .destroyed)
        do { try loaded.show(in: harness.player.view) } catch VideoAdError.destroyed {} catch {
            Issue.record("one spelling: destroyed, never invalidated(.destroyed); got \(error)")
        }
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
        #expect(await notUsedBeacons(expecting: 1).map(\.bidId) == ["img-d-new"], "one notice, for the valid ad")
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
        #expect(ads.playhead == 0 && ads.playback.isTracking && !ads.playback.isPlaying, "a player that is gone plays nothing")
    }
}
}
