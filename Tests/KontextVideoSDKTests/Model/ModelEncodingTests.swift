import Foundation
@testable import KontextVideoSDK
import Testing

/// What the app passes in, as the wire sees it: `KontextVideo.Content`, `User`, `Regulatory`, the
/// options. Seconds become milliseconds, `nil` fields are absent, nothing is defaulted on the app's behalf.
struct ModelEncodingTests {
    // MARK: Content

    @Test func contentEncodesRequiredFieldsOnly() throws {
        let json = try Fixtures.encode(KontextVideo.Content(id: "v1", language: "en"))
        #expect(json["id"] as? String == "v1")
        #expect(json["language"] as? String == "en")
        #expect(json.count == 2, "nothing else is sent: \(json.keys.sorted())")
        #expect(json["mediaRating"] == nil, "unset means unknown; the SDK never guesses .safe")
    }

    @Test func contentEncodesEverythingInMilliseconds() throws {
        let content = KontextVideo.Content(
            id: "100001-6", language: "pt-BR", mediaRating: .explicit, url: URL(string: "https://p.test/ep/6"),
            title: "Episode 6", categories: ["640"], description: "d", duration: 92.4, episodeNumber: 6,
            keywords: ["love"], genre: "romance", series: .init(id: "100001", title: "S", description: "sd", episodeCount: 40)
        )
        let json = try Fixtures.encode(content)
        #expect(json["mediaRating"] as? String == "explicit")
        #expect(json["duration"] as? Int == 92_400, "seconds on the API, milliseconds on the wire")
        #expect(json["url"] as? String == "https://p.test/ep/6")
        #expect(json["episodeNumber"] as? Int == 6)
        #expect((json["series"] as? [String: Any])?["episodeCount"] as? Int == 40)
        #expect((json["series"] as? [String: Any])?["title"] as? String == "S")
    }

    @Test func contentDurationRoundsToNearestMillisecond() throws {
        let json = try Fixtures.encode(KontextVideo.Content(id: "v", language: "en", duration: 1.0004))
        #expect(json["duration"] as? Int == 1000)
    }

    @Test func contentIsEquatable() {
        let a = KontextVideo.Content(id: "v", language: "en", duration: 10)
        let b = KontextVideo.Content(id: "v", language: "en", duration: 10)
        #expect(a == b)
        #expect(a != KontextVideo.Content(id: "v", language: "cs", duration: 10))
    }

    // MARK: User, Regulatory

    @Test func userEncodesOnlySetFields() throws {
        let json = try Fixtures.encode(KontextVideo.User(id: "u1", email: "a@b.c", yearOfBirth: 1994, gender: .female))
        #expect(json["id"] as? String == "u1")
        #expect(json["email"] as? String == "a@b.c")
        #expect(json["yearOfBirth"] as? Int == 1994)
        #expect(json["gender"] as? String == "female")
        #expect(json["emailHash"] == nil)
        #expect(json["keywords"] == nil)
    }

    @Test func userEqualityDrivesTargetingChanges() {
        #expect(KontextVideo.User(id: "u1") == KontextVideo.User(id: "u1"))
        #expect(KontextVideo.User(id: "u1") != KontextVideo.User(id: "u2"))
    }

    @Test func regulatoryEncodesEveryField() throws {
        let json = try Fixtures.encode(KontextVideo.Regulatory(gdpr: true, gdprConsent: "TC", coppa: false, gpp: "GPP", gppSid: [2, 7], usPrivacy: "1YNN"))
        #expect(json["gdpr"] as? Bool == true)
        #expect(json["gdprConsent"] as? String == "TC")
        #expect(json["coppa"] as? Bool == false)
        #expect(json["gpp"] as? String == "GPP")
        #expect(json["gppSid"] as? [Int] == [2, 7])
        #expect(json["usPrivacy"] as? String == "1YNN")
    }

    @Test func regulatoryOmitsNilFields() throws {
        let json = try Fixtures.encode(KontextVideo.Regulatory(coppa: true))
        #expect(json.count == 1)
        #expect(json["coppa"] as? Bool == true)
    }

    // MARK: Options

    @Test func overlayOptionsEncodePositions() throws {
        let json = try Fixtures.encode(OverlayOptions(positions: [.bottom]))
        #expect(json["positions"] as? [String] == ["bottom"])
        #expect(try Fixtures.encode(OverlayOptions()).isEmpty, "every option is optional")
    }

    @Test func pauseOptionsEncodePositionsIncludingFullscreen() throws {
        let json = try Fixtures.encode(PauseOptions(positions: [.top, .fullscreen]))
        #expect(json["positions"] as? [String] == ["top", "fullscreen"])
    }

    @Test func interstitialOptionsEncodeMaxDurationInMilliseconds() throws {
        let json = try Fixtures.encode(InterstitialOptions(timing: .preroll, maxDuration: 30, muted: true, rewarded: false))
        #expect(json["timing"] as? String == "preroll")
        #expect(json["maxDuration"] as? Int == 30_000)
        #expect(json["muted"] as? Bool == true)
        #expect(json["rewarded"] as? Bool == false)
        #expect(try Fixtures.encode(InterstitialOptions()).isEmpty)
    }

    @Test func adFormatRawValuesMatchTheWire() {
        #expect(AdFormat.overlay.rawValue == "overlay")
        #expect(AdFormat.pause.rawValue == "pause")
        #expect(AdFormat.interstitial.rawValue == "interstitial")
    }

    // MARK: Configuration

    @Test func configurationDefaults() {
        let configuration = KontextVideo.Configuration(publisherToken: "pub-dev")
        #expect(configuration.publisherToken == "pub-dev")
        #expect(configuration.requestTrackingAuthorization == false, "the app decides when the ATT dialog appears")
        #expect(configuration.logLevel == .warning)
        #expect(configuration.adServerURL == KontextVideo.Configuration.defaultAdServerURL)
        #expect(KontextVideo.Configuration.defaultAdServerURL.absoluteString == "https://server.megabrain.co")
    }

    @Test func logLevelsAreOrdered() {
        #expect(KontextVideo.Configuration.LogLevel.none < .error)
        #expect(KontextVideo.Configuration.LogLevel.error < .warning)
        #expect(KontextVideo.Configuration.LogLevel.warning < .info)
        #expect(KontextVideo.Configuration.LogLevel.info < .debug)
    }

    // MARK: SDKInfo

    @Test func sdkInfoIsASemanticVersion() throws {
        #expect(SDKInfo.current.name == "sdk-swift-video")
        let parts = SDKInfo.current.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
        let json = try Fixtures.encode(SDKInfo.current)
        #expect(json["name"] as? String == "sdk-swift-video")
        #expect(json["version"] as? String == SDKInfo.current.version)
    }
}
