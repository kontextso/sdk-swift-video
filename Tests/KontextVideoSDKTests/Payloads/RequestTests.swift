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
        #expect((device?["os"] as? [String: Any])?["name"] as? String == "ios")
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

    private func makeAdsRequest(playhead: TimeInterval = 12.345) -> AdsRequest {
        KontextVideo.shared.user = KontextVideo.User(id: "u1")
        KontextVideo.shared.variantId = "exp-b"
        KontextVideo.shared.regulatory = KontextVideo.Regulatory(coppa: false)
        return AdsRequest.make(
            sdk: KontextVideo.shared,
            configuration: configuration,
            tracking: TrackingInfo(ifa: IFA(id: "6D92078A-8246-4BA4-AE5B-76104861E7DC"), status: .authorized),
            content: KontextVideo.Content(id: "v1", language: "en", duration: 92),
            player: PlayerSnapshot(width: 390, height: 844, fullscreen: true, playhead: Int((playhead * 1000).rounded())),
            sessionId: "s-1",
            held: ["a-1", "a-2"]
        )
    }

    @Test func adsRequestBodyHasEveryField() throws {
        let json = try Fixtures.encode(makeAdsRequest())
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

    @Test func adsRequestOmitsIfaWhenNotAuthorized() throws {
        var request = makeAdsRequest()
        request = AdsRequest.make(
            sdk: KontextVideo.shared, configuration: configuration,
            tracking: TrackingInfo(ifa: nil, status: .denied),
            content: KontextVideo.Content(id: "v", language: "en"), player: .make(playheadMs: 0),
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
        let snapshot = PlayerSnapshot.make(playheadMs: 47_001)
        #expect(snapshot.width == 844 && snapshot.height == 390, "landscape: the key window's size in points")
        #expect(snapshot.fullscreen)
        #expect(snapshot.playhead == 47_001)
        Environment.keyWindow = { nil }
        let bare = PlayerSnapshot.make(playheadMs: 0)
        #expect(bare.fullscreen, "no window yet: the main screen")
        #expect(bare.width == Int(UIScreen.main.bounds.width.rounded()))
    }

    // MARK: Device facts

    @Test func deviceFactsHaveTheWireShape() throws {
        let device = try Fixtures.encode(AdsDevice.current())
        let screen = device["screen"] as? [String: Any]
        #expect((screen?["width"] as? Int ?? 0) > 0)
        #expect((screen?["dpr"] as? Double ?? 0) >= 1)
        #expect(screen?["darkMode"] is Bool)
        let os = device["os"] as? [String: Any]
        #expect(os?["name"] as? String == "ios")
        #expect(os?["locale"] is String)
        #expect(os?["timezone"] is String)
        let hardware = device["hardware"] as? [String: Any]
        #expect(["phone", "tablet", "tv", "desktop", "other"].contains(hardware?["type"] as? String ?? ""))
        let userAgent = (device["network"] as? [String: Any])?["userAgent"] as? String
        #expect(userAgent?.contains("KontextVideo/") == true)
    }

    // MARK: Privacy

    @Test func trackingInfoWithoutTheDialogReportsTheStatus() async {
        let info = await TrackingInfo.current(requestAuthorization: false)
        #expect(["authorized", "denied", "notDetermined", "restricted"].contains(info.attStatus))
        if info.attStatus != "authorized" {
            #expect(info.ifa == nil, "no id unless authorized")
        }
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
