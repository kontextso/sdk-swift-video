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
        guard case .enabled(let reportDebug, _) = response else { Issue.record("expected enabled"); return }
        #expect(reportDebug == true)
    }

    @Test func configEnabledDefaultsReportDebugToFalse() throws {
        guard case .enabled(let reportDebug, _) = try decode(ConfigResponse.self, ["enabled": true]) else { Issue.record("expected enabled"); return }
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

    @Test func onlyFidelitiesZeroAndOneCount() throws {
        var unsupportedOnly = Fixtures.skan(fidelities: [2])
        #expect(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": unsupportedOnly]])).attribution?.skan == nil)
        unsupportedOnly = Fixtures.skan(fidelities: [1, 2])
        let kept = try #require(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": unsupportedOnly]])).attribution?.skan)
        #expect(kept.fidelities.map(\.fidelity) == [1] && kept.hasFidelity1 && !kept.hasFidelity0)
        let clickOnly = try #require(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": Fixtures.skan(fidelities: [1])]])).attribution?.skan)
        #expect(clickOnly.hasFidelity1 && !clickOnly.hasFidelity0, "signed for the click only: valid")
    }

    @Test func anEntryThatDoesNotDecodeIsDroppedAndTheRestKept() throws {
        var skan = Fixtures.skan()
        skan["fidelities"] = [["fidelity": 0, "nonce": "n", "timestamp": "1", "signature": "s"], ["fidelity": 2], "junk"]
        let attribution = try #require(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": skan, "aak": ["jws": "j"]]])).attribution)
        #expect(attribution.skan?.fidelities.map(\.fidelity) == [0], "the fidelity 0 survives a future entry in another shape")
        #expect(attribution.aakJWS == "j")
    }

    @Test func badEntriesBeforeAndBetweenGoodOnesAreSkipped() throws {
        var skan = Fixtures.skan()
        skan["fidelities"] = [
            NSNull(), 7, ["fidelity": 1, "nonce": "n"],              // null, a scalar, a malformed supported entry
            ["fidelity": 0, "nonce": "a", "timestamp": "1", "signature": "s"],
            "junk", ["fidelity": 2, "nonce": "b", "timestamp": "1", "signature": "t"],
            ["fidelity": 1, "nonce": "c", "timestamp": "1", "signature": "u"],
        ]
        let attribution = try #require(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": skan, "aak": ["jws": "j"]]])).attribution)
        #expect(attribution.skan?.fidelities.map(\.fidelity) == [0, 1], "both good entries survive, whatever comes before them")
        #expect(attribution.skan?.fidelities.last?.nonce == "c")
        #expect(attribution.aakJWS == "j")
    }

    @Test func theSameFidelityTwiceDropsThePayload() throws {
        var skan = Fixtures.skan()
        skan["fidelities"] = [["fidelity": 0, "nonce": "a", "timestamp": "1", "signature": "s"], ["fidelity": 0, "nonce": "b", "timestamp": "1", "signature": "t"]]
        let attribution = try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": skan, "aak": ["jws": "j"]]])).attribution
        #expect(attribution?.skan == nil, "which one signs would depend on the order")
        #expect(attribution?.aakJWS == "j")
        var clickTwice = Fixtures.skan()
        clickTwice["fidelities"] = [["fidelity": 1, "nonce": "a", "timestamp": "1", "signature": "s"], ["fidelity": 1, "nonce": "b", "timestamp": "1", "signature": "t"]]
        #expect(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": clickTwice]])).attribution?.skan == nil, "fidelity 1 twice too")
    }

    @Test func anEmptyRequiredStringIsMissing() throws {
        var emptySignature = Fixtures.skan()
        emptySignature["fidelities"] = [["fidelity": 0, "nonce": "n", "timestamp": "1", "signature": ""]]
        var emptyNetwork = Fixtures.skan()
        emptyNetwork["network"] = ""
        for skan in [emptySignature, emptyNetwork] {
            let payload = try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": skan]]))
            #expect(payload.id == "ad-1" && payload.attribution?.skan == nil)
        }
        var emptyOptional = Fixtures.skan()
        emptyOptional["campaign"] = ""
        #expect(try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": emptyOptional]])).attribution?.skan?.campaign == nil, "an empty optional is absent")
    }

    @Test func aMalformedSKANNextToAValidAAKKeepsTheJWS() throws {
        let payload = try Fixtures.payload(Fixtures.ad(extra: ["attribution": ["skan": "broken", "aak": ["jws": "eyJ.e30.sig"]]]))
        #expect(payload.attribution?.skan == nil && payload.attribution?.aakJWS == "eyJ.e30.sig")
    }

    // MARK: Consistency

    @Test func anAdOfAnotherFormatThanItsResultFailsTheResponse() throws {
        let stray = Fixtures.overlayAd(id: "o-in-pause")
        #expect(throws: DecodingError.self) {
            try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [stray]]]])
        }
        _ = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "overlay", "ads": [stray]]]])
    }

    @Test func aFormatListedTwiceFailsTheResponse() throws {
        let noFill: [String: Any] = ["format": "pause", "ads": [], "noFillReason": "frequencyCap"]
        let filled: [String: Any] = ["format": "pause", "ads": [Fixtures.ad()]]
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [noFill, filled]]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [filled, noFill]]) }
        let once = try decode(AdsResponse.self, ["enabled": true, "formats": [filled, ["format": "overlay", "ads": []]]])
        #expect(once.result(for: .pause)?.ads.count == 1)
    }

    @Test func clearlyBrokenAdsAreRefused() throws {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(id: "")) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(expires: 0)) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(expires: -5)) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.overlayAd(duration: -1)) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.linearAd(skipOffset: -1)) }
        #expect(try Fixtures.payload(Fixtures.linearAd(skipOffset: 0)).id == "ad-i", "a Close from the start is fine")
    }

    @Test func anAbsurdSizeIsRefused() {
        for side in [10_001, Int.max] {
            #expect(throws: DecodingError.self, "\(side)") { try Fixtures.payload(Fixtures.ad(size: ["width": side, "height": 250])) }
        }
        #expect(throws: Never.self) { try Fixtures.payload(Fixtures.ad(size: ["width": 10_000, "height": 250])) }
    }

    @Test func aSizeSaysWhetherItMayShrink() throws {
        let fixed = try Fixtures.payload(Fixtures.ad(size: ["width": 300, "height": 250, "scalable": false]))
        guard case .pause(_, let sizes) = fixed.details else { Issue.record("expected pause"); return }
        #expect(sizes == [AdPayload.Size(width: 300, height: 250, scalable: false)])
        let unsaid = try Fixtures.payload(Fixtures.ad(size: ["width": 300, "height": 250]))
        guard case .pause(_, let defaulted) = unsaid.details else { Issue.record("expected pause"); return }
        #expect(defaulted.first?.scalable == true, "absent is scalable")
    }

    @Test func theFrameURLMustBeAbsoluteWithAHost() throws {
        for ok in ["https://server.kontext.so/frame/ad-1", "http://localhost:5175/frame/ad-1", "kontext-test://frames/frame/ad-1"] {
            #expect(try Fixtures.payload(Fixtures.ad(frameURL: ok)).rendering == .frame(URL(string: ok)!))
        }
        for bad in ["frame/ad-1", "/frame/ad-1", "file:///etc/passwd", "file://localhost/etc/passwd", "javascript:alert(1)", "data:text/html,hi", "blob:https://x/y", "about:blank"] {
            #expect(throws: DecodingError.self, "\(bad)") { try Fixtures.payload(Fixtures.ad(frameURL: bad)) }
        }
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

    // MARK: Edges

    @Test func aConfigAnswerNeedsABooleanEnabledAndToleratesTheRest() throws {
        for body in [[:], ["enabled": NSNull()], ["enabled": "true"], ["enabled": 1]] as [[String: Any]] {
            #expect(throws: DecodingError.self, "\(body)") { try decode(ConfigResponse.self, body) }
        }
        for reportDebug in [NSNull(), "yes", 1] as [Any] {
            guard case .enabled(let flag, let errors) = try decode(ConfigResponse.self, ["enabled": true, "reportDebug": reportDebug, "reportErrors": reportDebug]) else { Issue.record("expected enabled"); continue }
            #expect(flag == false && errors == false, "a malformed reportDebug or reportErrors is off: \(reportDebug)")
        }
        guard case .enabled(_, let missing) = try decode(ConfigResponse.self, ["enabled": true]) else { Issue.record("expected enabled"); return }
        #expect(missing == false, "reportErrors left out is off")
        guard case .enabled(_, let on) = try decode(ConfigResponse.self, ["enabled": true, "reportErrors": true]) else { Issue.record("expected enabled"); return }
        #expect(on)
        for reason in [NSNull(), 42] as [Any] {
            guard case .disabled(let text) = try decode(ConfigResponse.self, ["enabled": false, "disabledReason": reason]) else { Issue.record("expected disabled"); continue }
            #expect(text == "unknown", "\(reason)")
        }
        guard case .disabled(let future) = try decode(ConfigResponse.self, ["enabled": false, "disabledReason": "aReasonFromTheFuture"]) else { Issue.record("expected disabled"); return }
        #expect(future == "aReasonFromTheFuture", "an unknown reason passes through")
    }

    @Test func anAdsAnswerEdges() throws {
        // Disabled wins without reading formats, even malformed ones.
        guard case .disabled = try decode(AdsResponse.self, ["enabled": false, "disabledReason": "publisherDisabled", "formats": "junk"]) else { Issue.record("expected disabled"); return }
        // A filled entry ignores a contradictory no-fill reason.
        let filled = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [Fixtures.ad()], "noFillReason": "frequencyCap"]]])
        #expect(filled.result(for: .pause)?.noFillReason == nil && filled.result(for: .pause)?.ads.count == 1)
        // A malformed or mismatched second ad fails the response, although only the first is used today.
        var broken = Fixtures.ad(id: "ad-2")
        broken["sizes"] = []
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [Fixtures.ad(), broken]]]]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [Fixtures.ad(), Fixtures.overlayAd()]]]]) }
    }

    @Test func adPayloadEdges() throws {
        var estimated = Fixtures.ad()
        estimated["price"] = ["model": "cpm", "value": 3.25, "currency": "EUR", "precision": "estimated"]
        let descriptor = try Fixtures.descriptor(estimated)
        #expect(descriptor.price == VideoAd.Price(value: 3.25, currency: "EUR", precision: .estimated))
        #expect(try Fixtures.payload(Fixtures.overlayAd(duration: 0)).id == "ad-o", "a zero duration is valid")
        for bad in ["FILE://localhost/etc/passwd", "JavaScript://x/alert(1)", "Data://x/y"] {
            #expect(throws: DecodingError.self, "\(bad)") { try Fixtures.payload(Fixtures.ad(frameURL: bad)) }
        }
        #expect(throws: DecodingError.self, "a scalable flag of the wrong type is a malformed size") {
            try Fixtures.payload(Fixtures.ad(size: ["width": 300, "height": 250, "scalable": "no"]))
        }
    }

    @Test func anErrorItemIsSummarizedByTitleThenDetailThenCode() throws {
        let decodeItems = { (items: [[String: Any]]) in try self.decode(ErrorResponse.self, ["errors": items]).errors.map(\.summary) }
        #expect(try decodeItems([["title": "T", "detail": "D", "code": "C"]]) == ["T"])
        #expect(try decodeItems([["detail": "D", "code": "C"]]) == ["D"], "detail when there is no title")
        #expect(try decodeItems([["code": "C"]]) == ["C"])
        #expect(try decodeItems([["title": "", "detail": "D"]]) == [""], "an empty title is shown as it is: the server's bug made visible")
        #expect(try decodeItems([[:]]) == [nil])
        #expect(throws: DecodingError.self, "a non-object entry fails the body; the client then reports the status alone") {
            try self.decode(ErrorResponse.self, ["errors": [["title": "T"], "junk"]])
        }
    }

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
