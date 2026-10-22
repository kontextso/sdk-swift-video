import Foundation
@testable import KontextVideoSDK
import Testing

/// Every branch of the wire's answers: `/config`, `/video/ads`, the ad payload for each format.
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: ConfigResponse

    @Test func configEnabledWithReportDebug() throws {
        let response = try decode(ConfigResponse.self, ["enabled": true, "reportDebug": true])
        guard case .enabled(let reportDebug) = response else { Issue.record("expected enabled"); return }
        #expect(reportDebug == true)
    }

    @Test func configEnabledDefaultsReportDebugToFalse() throws {
        guard case .enabled(let reportDebug) = try decode(ConfigResponse.self, ["enabled": true]) else { Issue.record("expected enabled"); return }
        #expect(reportDebug == false)
    }

    @Test func configDisabledCarriesTheReason() throws {
        guard case .disabled(let reason) = try decode(ConfigResponse.self, Fixtures.disabled("appVersionDisabled")) else { Issue.record("expected disabled"); return }
        #expect(reason == "appVersionDisabled")
    }

    @Test func configDisabledWithoutReasonIsUnknown() throws {
        guard case .disabled(let reason) = try decode(ConfigResponse.self, ["enabled": false]) else { Issue.record("expected disabled"); return }
        #expect(reason == "unknown")
    }

    // MARK: AdsResponse

    @Test func adsResponseWithAdIgnoresTimedModeFields() throws {
        let response = try decode(AdsResponse.self, Fixtures.adsResponse(Fixtures.ad(), nextRequestAt: 25_000))
        let result = try #require(response.result(for: .pause))
        #expect(result.ads.first?.id == "ad-1")
        #expect(result.noFillReason == nil)
    }

    @Test func adsResponseAnswersPerFormat() throws {
        let response = try decode(AdsResponse.self, Fixtures.adsResponse(formats: [
            Fixtures.filledEntry(Fixtures.linearAd(id: "l1")),
            Fixtures.noFillEntry("frequencyCap", format: "overlay"),
            Fixtures.filledEntry(Fixtures.ad(id: "p1")),
        ]))
        #expect(response.result(for: .linear)?.ads.map(\.id) == ["l1"])
        #expect(response.result(for: .overlay)?.ads.isEmpty == true)
        #expect(response.result(for: .overlay)?.noFillReason == "frequencyCap")
        #expect(response.result(for: .pause)?.ads.map(\.id) == ["p1"])
        #expect(response.result(for: .overlay)?.format == .overlay)
    }

    @Test func adsResponseNoFillIgnoresWhatItDoesNotRead() throws {
        let response = try decode(AdsResponse.self, Fixtures.noFill("temporaryError", nextRequestAt: 38_000))
        #expect(response.result(for: .pause)?.noFillReason == "temporaryError")
    }

    @Test func adsResponseNoFillDefaults() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": []]]])
        #expect(response.result(for: .pause)?.noFillReason == "unknown")
    }

    @Test func adsResponseReasonsOfTheWrongTypeReadUnknown() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [], "noFillReason": 7]]])
        #expect(response.result(for: .pause)?.noFillReason == AdsResponse.unknownReason, "the answer is understood, the reason is not")
        guard case .disabled(let disabled) = try decode(AdsResponse.self, ["enabled": false, "disabledReason": ["x"]]) else { Issue.record("expected disabled"); return }
        #expect(disabled == AdsResponse.unknownReason)
    }

    @Test func adsResponseWithoutFormatsOrWithAnUnknownFormatIsRejected() {
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "banner", "ads": []]]]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause"]]]) }
    }

    @Test func aResponseForOtherFormatsHasNoEntryForThisOne() throws {
        let response = try decode(AdsResponse.self, Fixtures.adsResponse(Fixtures.linearAd()))
        #expect(response.result(for: .pause) == nil)
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
        #expect(ad.format == .pause)
        #expect(ad.creative == .image)
        #expect(ad.expires == 3_600_000)
        #expect(ad.price == AdPayload.Price(value: 7.5, currency: "USD", precision: .exact))
        #expect(ad.trigger == .manual)
        #expect(ad.rendering == .frame(URL(string: "kontext-test://frames/frame/ad-1")!))
        guard case .pause(let position, let sizes) = ad.details else { Issue.record("expected pause"); return }
        #expect(position == .top)
        #expect(sizes == [AdPayload.Size(width: 300, height: 300, scalable: true, maintainAspectRatio: true)])
    }

    @Test func fullscreenPauseAdHasNoSizes() throws {
        let ad = try Fixtures.payload(Fixtures.ad(position: "fullscreen", size: nil))
        guard case .pause(let position, let sizes) = ad.details else { Issue.record("expected pause"); return }
        #expect(position == .fullscreen)
        #expect(sizes.isEmpty)
    }

    @Test func anEmptySizesListIsRejected() {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(size: nil, extra: ["sizes": []])) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(size: nil)) }
    }

    @Test func overlayAdWithWindowTrigger() throws {
        let ad = try Fixtures.payload(Fixtures.ad(format: "overlay", trigger: ["kind": "window", "from": 4000, "to": 10_000], position: "bottom", duration: 6000))
        #expect(ad.format == .overlay)
        #expect(ad.trigger == .window(from: 4000, to: 10_000))
        guard case .overlay(let position, let sizes, let duration) = ad.details else { Issue.record("expected overlay"); return }
        #expect(position == .bottom)
        #expect(sizes.map(\.width) == [300])
        #expect(duration == 6000)
    }

    @Test func linearAdWithSkipOffsetAndReward() throws {
        let ad = try Fixtures.payload(Fixtures.linearAd(duration: 15_000, skipOffset: 5000, reward: ["label": "coins", "amount": 50]))
        #expect(ad.format == .linear)
        #expect(ad.creative == .video)
        guard case .linear(let duration, let skipOffset, let reward) = ad.details else { Issue.record("expected linear"); return }
        #expect(duration == 15_000)
        #expect(skipOffset == 5000)
        #expect(reward == AdPayload.Reward(label: "coins", amount: 50))
    }

    @Test func rewardedLinearHasNoSkipOffset() throws {
        let ad = try Fixtures.payload(Fixtures.linearAd(skipOffset: nil, reward: ["label": "coins", "amount": 50]))
        guard case .linear(_, let skipOffset, let reward) = ad.details else { Issue.record("expected linear"); return }
        #expect(skipOffset == nil)
        #expect(reward != nil)
    }

    @Test func trackingEntriesKeepOffsetAndPart() throws {
        let ad = try Fixtures.payload(Fixtures.linearAd())
        let progress = ad.tracking.first { $0.event == "progress" }
        #expect(progress?.offset == 5000)
        #expect(progress?.part == nil)
        let endCard = ad.tracking.first { $0.event == "creativeView" && $0.part == "endCard" }
        #expect(endCard != nil)
        #expect(ad.tracking.filter { $0.event == "click" }.count == 2, "the creative's and the end card's")
    }

    @Test func anAdWithoutAVastUrlDecodes() throws {
        var ad = Fixtures.ad()
        ad["vastUrl"] = nil
        #expect(try Fixtures.payload(ad).id == "ad-1", "the SDK never reads it; it is for players that render VAST")
    }

    @Test func unknownTriggerKindIsRejected() {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(trigger: ["kind": "timer"])) }
    }

    @Test func unknownRenderingKindIsRejected() {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(extra: ["rendering": ["kind": "native", "url": "x"]])) }
    }

    @Test func aPlacementIdOnTheWireIsIgnored() throws {
        var ad = Fixtures.ad()
        ad["placementId"] = "legacy"
        #expect(try Fixtures.payload(ad).id == "ad-1", "an older server's field; the SDK never reads it")
    }

    @Test func unknownFormatIsRejected() {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(format: "banner")) }
    }

    // MARK: APIErrorResponse

    @Test func errorResponseNeedsOnlyTheCode() throws {
        let response = try decode(APIErrorResponse.self, ["errors": [["code": "invalidRequest"]]])
        #expect(response.errors.first?.code == "invalidRequest")
        #expect(response.errors.first?.title == nil)
        #expect(APIError.http(status: 400, errors: response.errors).description == "HTTP 400: invalidRequest", "the code stands in for a missing title")
    }

    @Test func errorResponseSurvivesAnItemWithoutACodeOrWithWrongTypes() throws {
        let response = try decode(APIErrorResponse.self, ["errors": [["title": "Something broke"], ["code": 42, "title": ["not", "a", "string"]], ["code": "rateLimited"]]])
        #expect(response.errors.map(\.code) == ["unknown", "unknown", "rateLimited"], "nothing is dropped, the unknown is named")
        #expect(APIError.http(status: 500, errors: response.errors).description == "HTTP 500: Something broke; unknown; rateLimited")
    }

    @Test func errorResponseDecodes() throws {
        let response = try decode(APIErrorResponse.self, ["errors": [["status": "429", "code": "rateLimited", "title": "slow down"]]])
        #expect(response.errors.first?.code == "rateLimited")
        #expect(response.errors.first?.detail == nil)
    }
}
