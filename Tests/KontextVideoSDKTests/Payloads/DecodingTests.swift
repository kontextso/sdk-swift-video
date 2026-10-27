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
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [Fixtures.ad()], "nextRequestAt": 25_000]]])
        let result = try #require(response.result(for: .pause))
        #expect(result.ads.first?.id == "ad-1")
        #expect(result.noFillReason == nil)
    }

    @Test func adsResponseAnswersPerFormat() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [
            Fixtures.filledEntry(Fixtures.linearAd(id: "l1")),
            Fixtures.noFillEntry("frequencyCap", format: "overlay"),
            Fixtures.filledEntry(Fixtures.ad(id: "p1")),
        ]])
        #expect(response.result(for: .linear)?.ads.map(\.id) == ["l1"])
        #expect(response.result(for: .overlay)?.ads.isEmpty == true)
        #expect(response.result(for: .overlay)?.noFillReason == .frequencyCap)
        #expect(response.result(for: .pause)?.ads.map(\.id) == ["p1"])
        #expect(response.result(for: .overlay)?.format == .overlay)
    }

    @Test func adsResponseNoFillIgnoresWhatItDoesNotRead() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [Fixtures.noFillEntry("temporaryError", format: "pause", nextRequestAt: 38_000)]])
        #expect(response.result(for: .pause)?.noFillReason == .temporaryError)
    }

    @Test func adsResponseNoFillDefaults() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": []]]])
        #expect(response.result(for: .pause)?.noFillReason == .unknown)
    }

    @Test func adsResponseNoFillReasonsTheSDKDoesNotKnowPassThrough() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [Fixtures.noFillEntry("brandNew", format: "pause")]])
        #expect(response.result(for: .pause)?.noFillReason == .other("brandNew"))
        #expect(response.result(for: .pause)?.noFillReason?.description == "brandNew", "the wire name survives for logs")
    }

    @Test func aSizeMustBePositive() throws {
        var payload = Fixtures.ad()
        payload["sizes"] = [["width": 0, "height": 300]]
        #expect(throws: DecodingError.self) { try Fixtures.payload(payload) }
    }

    @Test func adsResponseReasonsOfTheWrongTypeReadUnknown() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [], "noFillReason": 7]]])
        #expect(response.result(for: .pause)?.noFillReason == .unknown, "the answer is understood, the reason is not")
        guard case .disabled(let disabled) = try decode(AdsResponse.self, ["enabled": false, "disabledReason": ["x"]]) else { Issue.record("expected disabled"); return }
        #expect(disabled == AdsResponse.unknownReason)
    }

    @Test func adsResponseWithoutFormatsOrWithAnUnknownFormatIsRejected() {
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "banner", "ads": []]]]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause"]]]) }
    }

    @Test func aResponseForOtherFormatsHasNoEntryForThisOne() throws {
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [Fixtures.filledEntry(Fixtures.linearAd())]])
        #expect(response.result(for: .pause) == nil)
    }

    @Test func adsResponseDisabled() throws {
        guard case .disabled(let reason) = try decode(AdsResponse.self, Fixtures.disabled("publisherDisabled")) else { Issue.record("expected disabled"); return }
        #expect(reason == "publisherDisabled")
    }

    @Test func adsResponseRequiresEnabled() {
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["ad": Fixtures.ad()]) }
    }

    // MARK: Attribution

    @Test func anAppInstallAdCarriesItsSKAdNetworkPayload() throws {
        var ad = Fixtures.installAd(Fixtures.ad(), itunesItem: "1521454264")
        ad["attribution"] = ["skan": Fixtures.skan(), "aak": ["jws": "eyJhbGciOiJFUzI1NiJ9.e30.sig"]]
        let payload = try Fixtures.payload(ad)
        let skan = try #require(payload.attribution?.skan)
        #expect(skan.version == "4.0" && skan.network == "mp7rpxwdrx.adattributionkit")
        #expect(skan.itunesItem == "1521454264" && skan.sourceApp == "6479835900" && skan.sourceIdentifier == "4021" && skan.campaign == nil)
        #expect(skan.fidelities.map(\.fidelity) == [1, 0] && skan.hasFidelity1)
        let viewThrough = skan.fidelities[1]
        #expect(viewThrough.nonce == "3f2c1a9e-0000" && viewThrough.timestamp == "1790850000000" && viewThrough.signature == "MEUCIQ0")
        #expect(payload.attribution?.aakJWS == "eyJhbGciOiJFUzI1NiJ9.e30.sig")
        #expect(try Fixtures.descriptor(ad).skan == skan, "the descriptor hands it to the ad")
        let raw = skan.rawDictionary()
        #expect(raw["itunesItem"] as? String == "1521454264" && raw["sourceIdentifier"] as? String == "4021" && raw["campaign"] == nil)
        #expect((raw["fidelities"] as? [[String: Any]])?.map { $0["fidelity"] as? Int } == [1, 0])
    }

    @Test func anAdWithoutAttributionHasNone() throws {
        #expect(try Fixtures.payload(Fixtures.ad()).attribution == nil)
        #expect(try Fixtures.descriptor(Fixtures.ad()).skan == nil)
    }

    @Test func numericSKAdNetworkIdsAreTakenAsStrings() throws {
        var skan = Fixtures.skan()
        skan["itunesItem"] = 1_521_454_264
        skan["sourceApp"] = 6_479_835_900
        skan["fidelities"] = [["fidelity": "1", "nonce": "n", "timestamp": 1_790_850_000_000, "signature": "s"]]
        let decoded = try #require(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": skan]])).attribution?.skan)
        #expect(decoded.itunesItem == "1521454264" && decoded.sourceApp == "6479835900")
        let entry = try #require(decoded.fidelities.first)
        #expect(decoded.fidelities.count == 1 && entry.fidelity == 1 && entry.timestamp == "1790850000000")
    }

    @Test func aMalformedSKAdNetworkPayloadDropsTheAttributionNotTheAd() throws {
        var missingNetwork = Fixtures.skan()
        missingNetwork["network"] = nil
        var noFidelities = Fixtures.skan()
        noFidelities["fidelities"] = []
        var brokenFidelity = Fixtures.skan()
        brokenFidelity["fidelities"] = [["fidelity": 1, "nonce": "n"]]
        var hugeFidelity = Fixtures.skan()
        hugeFidelity["fidelities"] = [["fidelity": 1e300, "nonce": "n", "timestamp": "1", "signature": "s"]]
        var fractionalFidelity = Fixtures.skan()
        fractionalFidelity["fidelities"] = [["fidelity": 1.5, "nonce": "n", "timestamp": "1", "signature": "s"]]
        for skan in [missingNetwork, noFidelities, brokenFidelity, hugeFidelity, fractionalFidelity, "not an object"] as [Any] {
            let payload = try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": skan]]))
            #expect(payload.id == "ad-1" && payload.attribution?.skan == nil, "\(skan)")
        }
        let payload = try Fixtures.payload(Fixtures.ad(extra: ["attribution": "nonsense"]))
        #expect(payload.id == "ad-1", "a broken attribution object does not fail the ad either")
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
        #expect(sizes == [AdPayload.Size(width: 300, height: 300)])
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

    @Test func linearAdWithSkipOffset() throws {
        let ad = try Fixtures.payload(Fixtures.linearAd(duration: 15_000, skipOffset: 5000))
        #expect(ad.format == .linear)
        #expect(ad.creative == .video)
        guard case .linear(let duration, let skipOffset) = ad.details else { Issue.record("expected linear"); return }
        #expect(duration == 15_000)
        #expect(skipOffset == 5000)
    }

    @Test func aLinearAdWithoutSkipOffsetHasNoCloseBeforeComplete() throws {
        let ad = try Fixtures.payload(Fixtures.linearAd(skipOffset: nil))
        guard case .linear(_, let skipOffset) = ad.details else { Issue.record("expected linear"); return }
        #expect(skipOffset == nil)
    }

    @Test func anHtmlCreativeDecodesAndAnUnknownKindIsRejected() throws {
        #expect(try Fixtures.payload(Fixtures.ad(creative: "html")).creative == .html)
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(creative: "native")) }
    }

    @Test func aRewardOnTheWireIsIgnored() throws {
        var linear = Fixtures.linearAd()
        linear["reward"] = ["label": "coins", "amount": 50]
        #expect(throws: Never.self) { try Fixtures.payload(linear) }
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

    // MARK: ErrorResponse

    @Test func errorResponseNeedsOnlyTheCode() throws {
        let response = try decode(ErrorResponse.self, ["errors": [["code": "invalidRequest"]]])
        #expect(response.errors.first?.code == "invalidRequest")
        #expect(response.errors.first?.title == nil)
        #expect(APIError.http(status: 400, errors: response.errors).description == "HTTP 400: invalidRequest", "the code stands in for a missing title")
    }

    @Test func errorResponseSurvivesAnItemWithoutACodeOrWithWrongTypes() throws {
        let response = try decode(ErrorResponse.self, ["errors": [["title": "Something broke"], ["code": 42, "title": ["not", "a", "string"]], ["code": "rateLimited"]]])
        #expect(response.errors.map(\.code) == [nil, nil, "rateLimited"], "nothing is dropped; a missing or malformed code is nil")
        #expect(APIError.http(status: 500, errors: response.errors).description == "HTTP 500: Something broke; rateLimited", "an item with nothing to say is left out of the line")
        #expect(APIError.http(status: 500, errors: [response.errors[1]]).description == "HTTP 500")
    }

    @Test func errorResponseDecodes() throws {
        let response = try decode(ErrorResponse.self, ["errors": [["status": "429", "code": "rateLimited", "title": "slow down"]]])
        #expect(response.errors.first?.code == "rateLimited")
        #expect(response.errors.first?.detail == nil)
    }
}
