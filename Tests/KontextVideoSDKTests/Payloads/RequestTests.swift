import AppTrackingTransparency
import AVFoundation
import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// What the SDK sends: the `/config` and `/video/ads` bodies, the player snapshot, device facts, privacy.
extension SerialSuites {
@Suite
@MainActor
struct RequestTests {
    init() { SDKHarness.reset() }

    private var configuration: KontextVideo.Configuration {
        KontextVideo.Configuration(publisherToken: "pub-dev", adServerURL: URL(string: "https://ads.test")!)
    }

    // MARK: ConfigRequest

    @Test func configRequestCarriesIdentityAndAttribution() throws {
        let request = ConfigRequest.make(configuration: configuration, installId: "install-1")
        let json = try Fixtures.encode(request)
        #expect(UUID(uuidString: request.requestId) != nil)
        #expect(request.requestId == request.requestId.lowercased())
        #expect(json["publisherToken"] as? String == "pub-dev")
        #expect(json["installId"] as? String == "install-1")
        #expect((json["sdk"] as? [String: Any])?["name"] as? String == "sdk-swift-video")
        #expect((json["app"] as? [String: Any])?["bundleId"] is String)
        let device = json["device"] as? [String: Any]
        #expect(["ios", "ipados", "tvos"].contains((device?["os"] as? [String: Any])?["name"] as? String ?? ""))
        #expect((device?["hardware"] as? [String: Any])?["brand"] as? String == "Apple")
        let attribution = json["attribution"] as? [String: Any]
        #expect(attribution?["skan"] is [String])
        #expect(attribution?["aak"] is [String])
    }

    @Test func eachConfigRequestHasItsOwnId() {
        let a = ConfigRequest.make(configuration: configuration, installId: "i")
        let b = ConfigRequest.make(configuration: configuration, installId: "i")
        #expect(a.requestId != b.requestId)
    }

    // MARK: AdsRequest

    private func makeAdsRequest(playhead: TimeInterval = 12.345) async -> AdsRequest {
        KontextVideo.shared.user = KontextVideo.User(id: "u1")
        KontextVideo.shared.variantId = "exp-b"
        KontextVideo.shared.regulatory = KontextVideo.Regulatory(coppa: false)
        return await AdsRequest.make(
            sdk: KontextVideo.shared,
            configuration: configuration,
            tracking: TrackingInfo(ifa: IFA(id: "6D92078A-8246-4BA4-AE5B-76104861E7DC"), status: .authorized),
            content: KontextVideo.Content(id: "v1", language: "en", duration: 92),
            labels: ["stage": "first_episode", "layout": "fullscreen"],
            player: PlayerSnapshot(width: 390, height: 844, fullscreen: true, playhead: Int((playhead * 1000).rounded())),
            sessionId: "s-1",
            held: ["a-1", "a-2"]
        )
    }

    @Test func adsRequestBodyHasEveryField() async throws {
        let json = try Fixtures.encode(await makeAdsRequest())
        #expect(json["adServerURL"] == nil, "where to send it is not part of the body")
        #expect(json["publisherToken"] as? String == "pub-dev")
        #expect(json["installId"] as? String == KontextVideo.installId)
        #expect((json["user"] as? [String: Any])?["id"] as? String == "u1")
        #expect(json["variantId"] as? String == "exp-b")
        #expect((json["ifa"] as? [String: Any])?["type"] as? String == "idfa")
        #expect((json["ifa"] as? [String: Any])?["limitAdTracking"] as? Bool == false)
        #expect(json["attStatus"] as? String == "authorized")
        #expect(json["idfv"] is String)
        #expect((json["regulatory"] as? [String: Any])?["coppa"] as? Bool == false)
        #expect(json["formats"] == nil, "no formats: the server answers every one")
        #expect(json["placementId"] == nil, "no placement ids on the wire")
        #expect(json["sessionId"] as? String == "s-1")
        #expect(json["held"] as? [String] == ["a-1", "a-2"])
        #expect(json["labels"] as? [String: String] == ["stage": "first_episode", "layout": "fullscreen"])
        #expect((json["video"] as? [String: Any])?["duration"] as? Int == 92_000)
        let player = json["player"] as? [String: Any]
        #expect(player?["width"] as? Int == 390)
        #expect(player?["height"] as? Int == 844)
        #expect(player?["fullscreen"] as? Bool == true)
        #expect(player?["playhead"] as? Int == 12_345)
        let device = json["device"] as? [String: Any]
        #expect((device?["screen"] as? [String: Any])?["dpr"] is Double)
        #expect((device?["network"] as? [String: Any])?["userAgent"] is String)
        #expect((device?["power"] as? [String: Any])?["lowPowerMode"] is Bool, "the server derives click-to-play from it")
        #expect(device?["audio"] != nil)
    }

    @Test func anAdsRequestCarriesExactlyWhatWasSetAndNothingElse() async throws {
        KontextVideo.shared.user = nil
        KontextVideo.shared.variantId = nil
        KontextVideo.shared.regulatory = nil
        let bare = try Fixtures.encode(await AdsRequest.make(
            sdk: KontextVideo.shared, configuration: configuration,
            tracking: TrackingInfo(ifa: IFA(id: "6D92078A-8246-4BA4-AE5B-76104861E7DC"), status: .authorized),
            content: KontextVideo.Content(id: "v", language: "en"), labels: [:], player: .make(playhead: 0), sessionId: "s", held: []
        ))
        #expect((bare["ifa"] as? [String: Any])?["id"] as? String == "6D92078A-8246-4BA4-AE5B-76104861E7DC", "the IDFA as given")
        #expect(bare["user"] == nil && bare["variantId"] == nil, "nothing the app did not set")
        #expect(bare["labels"] == nil, "no labels: the field is left out")
        let again = try Fixtures.encode(await AdsRequest.make(
            sdk: KontextVideo.shared, configuration: configuration, tracking: TrackingInfo(ifa: nil, status: .denied),
            content: KontextVideo.Content(id: "v", language: "en"), labels: [:], player: .make(playhead: 0), sessionId: "s", held: []
        ))
        #expect(bare["requestId"] as? String != again["requestId"] as? String, "a new id per request")
        KontextVideo.shared.user = KontextVideo.User(id: "later")
        let later = try Fixtures.encode(await AdsRequest.make(
            sdk: KontextVideo.shared, configuration: configuration, tracking: TrackingInfo(ifa: nil, status: .denied),
            content: KontextVideo.Content(id: "v", language: "en"), labels: [:], player: .make(playhead: 0), sessionId: "s", held: []
        ))
        #expect((later["user"] as? [String: Any])?["id"] as? String == "later", "a change reaches the next request")
        KontextVideo.shared.user = nil
    }

    @Test func adsRequestOmitsIfaWhenNotAuthorized() async throws {
        var request = await makeAdsRequest()
        request = await AdsRequest.make(
            sdk: KontextVideo.shared, configuration: configuration,
            tracking: TrackingInfo(ifa: nil, status: .denied),
            content: KontextVideo.Content(id: "v", language: "en"), labels: [:], player: .make(playhead: 0),
            sessionId: "s-2", held: []
        )
        let json = try Fixtures.encode(request)
        #expect(json["ifa"] == nil)
        #expect(json["attStatus"] as? String == "denied")
        #expect(json["held"] as? [String] == [], "nothing held: an empty list, never absent")
    }

    // MARK: PlayerSnapshot

    @Test func snapshotIsTheKeyWindowInItsOrientationFullScreen() {
        let window = TestWindow(size: CGSize(width: 844, height: 390))
        defer { window.tearDown() }
        Environment.keyWindow = { window.window }
        let snapshot = PlayerSnapshot.make(playhead: 47.0014)
        #expect(snapshot.width == 844 && snapshot.height == 390, "landscape: the key window's size in points")
        #expect(snapshot.fullscreen)
        #expect(snapshot.playhead == 47_001, "milliseconds on the wire, rounded")
        Environment.keyWindow = { nil }
        let bare = PlayerSnapshot.make(playhead: 0)
        #expect(bare.fullscreen, "no window yet: the main screen")
        #expect(bare.width == Int(UIScreen.main.bounds.width.rounded()))
    }

    // MARK: Device facts

    @Test func deviceFactsHaveTheWireShape() async throws {
        let device = try Fixtures.encode(await AdsDevice.current())
        let screen = device["screen"] as? [String: Any]
        #expect((screen?["width"] as? Int ?? 0) > 0)
        #expect((screen?["dpr"] as? Double ?? 0) >= 1)
        #expect(screen?["darkMode"] is Bool)
        let os = device["os"] as? [String: Any]
        #expect(["ios", "ipados", "tvos"].contains(os?["name"] as? String ?? ""), "the device's own idiom")
        #expect(os?["locale"] is String)
        #expect(os?["timezone"] is String)
        let hardware = device["hardware"] as? [String: Any]
        #expect(["phone", "tablet", "tv", "desktop", "other"].contains(hardware?["type"] as? String ?? ""))
        let userAgent = (device["network"] as? [String: Any])?["userAgent"] as? String
        #expect(userAgent?.hasPrefix("Mozilla/") == true, "the browser's user agent, as sdk-swift sends it: \(userAgent ?? "nil")")
    }

    // MARK: Privacy

    @Test func trackingInfoWithoutTheDialogReportsTheStatus() async throws {
        let info = try await TrackingInfo.current(requestAuthorization: false)
        #expect(["authorized", "denied", "notDetermined", "restricted"].contains(info.attStatus))
        if info.attStatus != "authorized" {
            #expect(info.ifa == nil, "no id unless authorized")
        }
    }

    @Test func concurrentRequestsShowTheDialogOnceAndBothGetTheAnswer() async throws {
        var prompts = 0
        let gate = Gate()
        Environment.trackingAuthorizationStatus = { .notDetermined }
        Environment.requestTrackingAuthorization = {
            prompts += 1
            while !gate.open { await sleepMs(5) }
            return .authorized
        }
        async let first = try TrackingInfo.current(requestAuthorization: true)
        async let second = try TrackingInfo.current(requestAuthorization: true)
        await sleepMs(40)
        gate.open = true
        let (a, b) = try await (first, second)
        #expect(prompts == 1, "one dialog for both")
        #expect(a.attStatus == "authorized" && b.attStatus == "authorized")
        Environment.trackingAuthorizationStatus = { .authorized }
        _ = try await TrackingInfo.current(requestAuthorization: true)
        #expect(prompts == 1, "answered: no dialog")
        Environment.trackingAuthorizationStatus = { .notDetermined }
        _ = try await TrackingInfo.current(requestAuthorization: false)
        #expect(prompts == 1, "not asked for: no dialog")
        _ = try await TrackingInfo.current(requestAuthorization: true)
        #expect(prompts == 2, "the shared task was cleared, a later request asks again")
    }

    @Test func anAppThatNeverAskedForTrackingIsWarnedOnceAtTheFirstRequest() async throws {
        Logger.level = .warning
        defer { Logger.level = .warning }
        var warnings: [String] = []
        Logger.sink = { level, message in
            if level == .warning, message.contains("App Tracking Transparency") { warnings.append(message) }
        }
        Environment.trackingAuthorizationStatus = { .authorized }
        _ = try await TrackingInfo.current(requestAuthorization: false)
        #expect(warnings.isEmpty, "answered: nothing to say")
        Environment.trackingAuthorizationStatus = { .notDetermined }
        Environment.requestTrackingAuthorization = { .denied }
        _ = try await TrackingInfo.current(requestAuthorization: true)
        #expect(warnings.isEmpty, "the SDK asks itself: nothing to say")
        for _ in 0..<3 {
            _ = try await TrackingInfo.current(requestAuthorization: false)
        }
        #expect(warnings.count == 1, "nobody asked: one warning across three requests, \(warnings.count) given")
    }

    final class Gate {
        var open = false
    }

    @Test func theIDFAIsSentOnlyWhenAuthorizedAndReal() async throws {
        let real = UUID(uuidString: "6D92078A-8246-4BA4-AE5B-76104861E7DC")!
        var prompts = 0
        Environment.requestTrackingAuthorization = { prompts += 1; return .authorized }
        Environment.advertisingIdentifier = { real }
        defer { Environment.reset() }
        for (status, name) in [(ATTrackingManager.AuthorizationStatus.denied, "denied"), (.restricted, "restricted"), (.notDetermined, "notDetermined")] {
            Environment.trackingAuthorizationStatus = { status }
            let info = try await TrackingInfo.current(requestAuthorization: false)
            #expect(info.ifa == nil && info.attStatus == name, "\(name): no IDFA, even a real one")
        }
        Environment.trackingAuthorizationStatus = { .authorized }
        #expect(try await TrackingInfo.current(requestAuthorization: false).ifa?.id == real.uuidString, "authorized: the IDFA as the OS gives it")
        Environment.advertisingIdentifier = { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
        #expect(try await TrackingInfo.current(requestAuthorization: false).ifa == nil, "authorized but all zeros: no IDFA")
        for status in [ATTrackingManager.AuthorizationStatus.authorized, .denied, .restricted] {
            Environment.trackingAuthorizationStatus = { status }
            _ = try await TrackingInfo.current(requestAuthorization: true)
        }
        #expect(prompts == 0, "an answered status never shows the dialog")
    }

    @Test func readingTheDeviceLeavesTheAppsAudioSessionAsItWas() async throws {
        let session = AVAudioSession.sharedInstance()
        let original = (session.category, session.mode, session.categoryOptions)
        defer { try? session.setCategory(original.0, mode: original.1, options: original.2) }
        try session.setCategory(.ambient, mode: .moviePlayback, options: [.duckOthers])
        // As iOS reports it back (it normalizes the options), before the SDK reads anything.
        let set = (session.category, session.mode, session.categoryOptions)
        let audio = AudioInfo.current()
        _ = await AdsDevice.current()
        #expect(session.category == set.0 && session.mode == set.1 && session.categoryOptions == set.2, "the app's audio session is the app's")
        #expect(set.0 == .ambient, "the app's own category was in place")
        #expect((0...100).contains(audio.volume))
        #expect(audio.muted == (audio.volume == 0) || audio.volume <= 1, "muted below 1 %")
    }

    @Test func consentStorageReadsTheIABKeys() {
        let defaults = UserDefaults(suiteName: "consent-test")!
        defaults.removePersistentDomain(forName: "consent-test")
        defaults.set(1, forKey: "IABTCF_gdprApplies")
        defaults.set("TC-STRING", forKey: "IABTCF_TCString")
        defaults.set("GPP-STRING", forKey: "IABGPP_HDR_GppString")
        defaults.set("2_7", forKey: "IABGPP_GppSID")
        defaults.set("1YNN", forKey: "IABUSPrivacy_String")
        let regulatory = ConsentStorage.read(merging: nil, defaults: defaults)
        #expect(regulatory?.gdpr == true)
        #expect(regulatory?.gdprConsent == "TC-STRING")
        #expect(regulatory?.gpp == "GPP-STRING")
        #expect(regulatory?.gppSid == [2, 7])
        #expect(regulatory?.usPrivacy == "1YNN")
        #expect(regulatory?.coppa == nil, "coppa can only come from the publisher")
    }

    @Test func consentStorageTheCMPWinsAndThePublisherFillsTheRest() {
        let defaults = UserDefaults(suiteName: "consent-test-2")!
        defaults.removePersistentDomain(forName: "consent-test-2")
        defaults.set(0, forKey: "IABTCF_gdprApplies")
        defaults.set("STORED", forKey: "IABTCF_TCString")
        let regulatory = ConsentStorage.read(merging: KontextVideo.Regulatory(gdpr: true, gdprConsent: "MINE", coppa: true, usPrivacy: "1YNN"), defaults: defaults)
        #expect(regulatory?.gdpr == false, "the CMP's live value wins")
        #expect(regulatory?.gdprConsent == "STORED")
        #expect(regulatory?.usPrivacy == "1YNN", "what the CMP did not write comes from the publisher")
        #expect(regulatory?.coppa == true, "coppa only ever comes from the publisher")
    }

    @Test func consentPrecedenceForEveryField() {
        let defaults = UserDefaults(suiteName: "consent-matrix")!
        defaults.removePersistentDomain(forName: "consent-matrix")
        let publisher = KontextVideo.Regulatory(gdpr: false, gdprConsent: "PUB-TC", coppa: false, gpp: "PUB-GPP", gppSid: [9], usPrivacy: "1NNN")

        // The CMP wrote nothing: every field from the publisher, explicit false included.
        let fallback = ConsentStorage.read(merging: publisher, defaults: defaults)
        #expect(fallback == publisher, "absent CMP values: the publisher's, false kept as false")

        // The CMP wrote valid values that conflict: each CMP value wins; coppa stays the publisher's.
        defaults.set(1, forKey: "IABTCF_gdprApplies")
        defaults.set("CMP-TC", forKey: "IABTCF_TCString")
        defaults.set("CMP-GPP", forKey: "IABGPP_HDR_GppString")
        defaults.set("2_7", forKey: "IABGPP_GppSID")
        defaults.set("1YNN", forKey: "IABUSPrivacy_String")
        let cmp = ConsentStorage.read(merging: publisher, defaults: defaults)
        #expect(cmp == KontextVideo.Regulatory(gdpr: true, gdprConsent: "CMP-TC", coppa: false, gpp: "CMP-GPP", gppSid: [2, 7], usPrivacy: "1YNN"))

        // Clearing the publisher's values leaves the CMP's in place.
        #expect(ConsentStorage.read(merging: nil, defaults: defaults) == KontextVideo.Regulatory(gdpr: true, gdprConsent: "CMP-TC", gpp: "CMP-GPP", gppSid: [2, 7], usPrivacy: "1YNN"))

        // The CMP's values become unusable: each field falls back to the publisher's.
        defaults.set("yes", forKey: "IABTCF_gdprApplies")
        defaults.set("", forKey: "IABTCF_TCString")
        defaults.set("", forKey: "IABGPP_HDR_GppString")
        defaults.set("x_y", forKey: "IABGPP_GppSID")
        defaults.set("", forKey: "IABUSPrivacy_String")
        #expect(ConsentStorage.read(merging: publisher, defaults: defaults) == publisher, "unusable CMP values: the publisher's")

        // The CMP changes between requests: the next read sees the new value.
        defaults.set(0, forKey: "IABTCF_gdprApplies")
        defaults.set("3", forKey: "IABGPP_GppSID")
        let changed = ConsentStorage.read(merging: publisher, defaults: defaults)
        #expect(changed?.gdpr == false && changed?.gppSid == [3])
    }

    @Test func consentStorageReadsGdprAppliesAsCMPsWriteIt() {
        let defaults = UserDefaults(suiteName: "consent-test-5")!
        defaults.removePersistentDomain(forName: "consent-test-5")
        for (raw, expected) in [(1 as Any, true), (0 as Any, false), (true as Any, true), ("1" as Any, true), ("0" as Any, false), (2 as Any, nil), ("yes" as Any, nil), (1.5 as Any, nil)] as [(Any, Bool?)] {
            defaults.set(raw, forKey: "IABTCF_gdprApplies")
            #expect(ConsentStorage.read(merging: nil, defaults: defaults)?.gdpr == expected, "\(raw) -> \(String(describing: expected))")
        }
    }

    @Test func consentStorageIsNilWhenNothingIsKnown() {
        let defaults = UserDefaults(suiteName: "consent-test-3")!
        defaults.removePersistentDomain(forName: "consent-test-3")
        defaults.set("", forKey: "IABTCF_TCString")
        defaults.set("", forKey: "IABGPP_GppSID")
        #expect(ConsentStorage.read(merging: nil, defaults: defaults) == nil, "empty strings count as absent")
    }

    @Test func consentStorageParsesSingleAndCommaSeparatedSids() {
        let defaults = UserDefaults(suiteName: "consent-test-4")!
        defaults.removePersistentDomain(forName: "consent-test-4")
        defaults.set("7", forKey: "IABGPP_GppSID")
        #expect(ConsentStorage.read(merging: nil, defaults: defaults)?.gppSid == [7])
        defaults.set("8,10", forKey: "IABGPP_GppSID")
        #expect(ConsentStorage.read(merging: nil, defaults: defaults)?.gppSid == [8, 10])
        defaults.set(7, forKey: "IABGPP_GppSID")
        #expect(ConsentStorage.read(merging: nil, defaults: defaults)?.gppSid == [7], "a CMP writing one section as a number")
        defaults.set("x_y", forKey: "IABGPP_GppSID")
        #expect(ConsentStorage.read(merging: nil, defaults: defaults)?.gppSid == nil, "junk is absent, not forwarded")
    }
}
}
