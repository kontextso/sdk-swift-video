import Foundation
@testable import KontextVideoSDK
import Testing

/// Every branch of the wire's answers: `/init`, `/video/ads`, the ad payload for each format.
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: InitResponse

    @Test func initEnabledWithReportDebug() throws {
        let response = try decode(InitResponse.self, ["enabled": true, "reportDebug": true])
        guard case .enabled(let reportDebug) = response else { Issue.record("expected enabled"); return }
        #expect(reportDebug == true)
    }

    @Test func initEnabledDefaultsReportDebugToFalse() throws {
        guard case .enabled(let reportDebug) = try decode(InitResponse.self, ["enabled": true]) else { Issue.record("expected enabled"); return }
        #expect(reportDebug == false)
    }

    @Test func initDisabledCarriesTheReason() throws {
        guard case .disabled(let reason) = try decode(InitResponse.self, Fixtures.disabled("appVersionDisabled")) else { Issue.record("expected disabled"); return }
        #expect(reason == "appVersionDisabled")
    }

    @Test func initDisabledWithoutReasonIsUnknown() throws {
        guard case .disabled(let reason) = try decode(InitResponse.self, ["enabled": false]) else { Issue.record("expected disabled"); return }
        #expect(reason == "unknown")
    }

    // MARK: AdsResponse

    @Test func adsResponseWithAd() throws {
        let response = try decode(AdsResponse.self, Fixtures.adsResponse(Fixtures.ad(), nextRequestAt: 25_000))
        guard case .ad(let ad, let next) = response else { Issue.record("expected ad"); return }
        #expect(ad.id == "ad-1")
        #expect(next == 25_000)
    }

    @Test func adsResponseNoFillWithRetryAfter() throws {
        let response = try decode(AdsResponse.self, Fixtures.noFill("temporaryError", retryAfter: 5000, nextRequestAt: 38_000))
        guard case .noFill(let reason, let retryAfter, let next) = response else { Issue.record("expected noFill"); return }
        #expect(reason == "temporaryError")
        #expect(retryAfter == 5000)
        #expect(next == 38_000)
    }

    @Test func adsResponseNoFillDefaults() throws {
        guard case .noFill(let reason, let retryAfter, let next) = try decode(AdsResponse.self, ["enabled": true]) else { Issue.record("expected noFill"); return }
        #expect(reason == "unknown")
        #expect(retryAfter == nil)
        #expect(next == nil)
    }

    @Test func adsResponseDisabled() throws {
        guard case .disabled(let reason) = try decode(AdsResponse.self, Fixtures.disabled("publisherDisabled")) else { Issue.record("expected disabled"); return }
        #expect(reason == "publisherDisabled")
    }

    @Test func adsResponseRequiresEnabled() {
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["ad": Fixtures.ad()]) }
    }

    // MARK: AdPayload per format

    @Test func pauseAdWithSize() throws {
        let ad = try Fixtures.payload(Fixtures.ad())
        #expect(ad.id == "ad-1")
        #expect(ad.placementId == "pause")
        #expect(ad.format == .pause)
        #expect(ad.creative == .image)
        #expect(ad.expires == 3_600_000)
        #expect(ad.price == AdPayload.Price(value: 7.5, currency: "USD", precision: .exact))
        #expect(ad.trigger == .manual)
        #expect(ad.rendering == .frame(URL(string: "kontext-test://frames/frame/ad-1")!))
        #expect(ad.vastUrl.absoluteString == "https://ads.test/v2/video/ads/ad-1/vast")
        guard case .pause(let position, let size) = ad.details else { Issue.record("expected pause"); return }
        #expect(position == .top)
        #expect(size == AdPayload.Size(width: 300, height: 300, scalable: true, maintainAspectRatio: true))
    }

    @Test func fullscreenPauseAdHasNoSize() throws {
        let ad = try Fixtures.payload(Fixtures.ad(position: "fullscreen", size: nil))
        guard case .pause(let position, let size) = ad.details else { Issue.record("expected pause"); return }
        #expect(position == .fullscreen)
        #expect(size == nil)
    }

    @Test func overlayAdWithWindowTrigger() throws {
        let ad = try Fixtures.payload(Fixtures.ad(format: "overlay", trigger: ["kind": "window", "from": 4000, "to": 10_000], position: "bottom", duration: 6000))
        #expect(ad.format == .overlay)
        #expect(ad.trigger == .window(from: 4000, to: 10_000))
        guard case .overlay(let position, let size, let duration) = ad.details else { Issue.record("expected overlay"); return }
        #expect(position == .bottom)
        #expect(size.width == 300)
        #expect(duration == 6000)
    }

    @Test func interstitialAdWithSkipOffsetAndReward() throws {
        let ad = try Fixtures.payload(Fixtures.interstitialAd(duration: 15_000, skipOffset: 5000, reward: ["label": "coins", "amount": 50]))
        #expect(ad.format == .interstitial)
        #expect(ad.creative == .video)
        guard case .interstitial(let duration, let skipOffset, let reward) = ad.details else { Issue.record("expected interstitial"); return }
        #expect(duration == 15_000)
        #expect(skipOffset == 5000)
        #expect(reward == AdPayload.Reward(label: "coins", amount: 50))
    }

    @Test func rewardedInterstitialHasNoSkipOffset() throws {
        let ad = try Fixtures.payload(Fixtures.interstitialAd(skipOffset: nil, reward: ["label": "coins", "amount": 50]))
        guard case .interstitial(_, let skipOffset, let reward) = ad.details else { Issue.record("expected interstitial"); return }
        #expect(skipOffset == nil)
        #expect(reward != nil)
    }

    @Test func trackingEntriesKeepOffsetAndPart() throws {
        let ad = try Fixtures.payload(Fixtures.interstitialAd())
        let progress = ad.tracking.first { $0.event == "progress" }
        #expect(progress?.offset == 5000)
        #expect(progress?.part == nil)
        let endCard = ad.tracking.first { $0.event == "creativeView" && $0.part == "endCard" }
        #expect(endCard != nil)
        #expect(ad.tracking.filter { $0.event == "click" }.count == 2, "the creative's and the end card's")
    }

    @Test func unknownTriggerKindIsRejected() {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(trigger: ["kind": "timer"])) }
    }

    @Test func unknownRenderingKindIsRejected() {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(extra: ["rendering": ["kind": "native", "url": "x"]])) }
    }

    @Test func missingPlacementIdIsRejected() {
        var ad = Fixtures.ad()
        ad["placementId"] = nil
        #expect(throws: DecodingError.self) { try Fixtures.payload(ad) }
    }

    @Test func unknownFormatIsRejected() {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(format: "banner")) }
    }

    // MARK: APIErrorResponse

    @Test func errorResponseDecodes() throws {
        let response = try decode(APIErrorResponse.self, ["errors": [["status": "429", "code": "rateLimited", "title": "slow down"]], "retryAfter": 1500])
        #expect(response.errors.first?.code == "rateLimited")
        #expect(response.errors.first?.detail == nil)
        #expect(response.retryAfter == 1500)
    }
}
