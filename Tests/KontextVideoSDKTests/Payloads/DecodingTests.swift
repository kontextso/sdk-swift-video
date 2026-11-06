import Foundation
@testable import KontextVideoSDK
import Testing

/// Every branch of the wire's answers: `/config`, `/video/ads`, the ad payload for each format.
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: ConfigResponse

    @Test func configEnabledOrDisabledWithItsReportDebugOrReason() throws {
        let cases: [(body: [String: Any], expected: String)] = [
            (["enabled": true, "reportDebug": true], "enabled reportDebug=true"),
            (["enabled": true], "enabled reportDebug=false"),
            (Fixtures.disabled("appVersionDisabled"), "disabled appVersionDisabled"),
            (["enabled": false], "disabled unknown"),
        ]
        for (body, expected) in cases {
            let response = try decode(ConfigResponse.self, body)
            let read = switch response {
            case .enabled(let reportDebug, _): "enabled reportDebug=\(reportDebug)"
            case .disabled(let reason): "disabled \(reason)"
            }
            #expect(read == expected, "\(body)")
        }
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

    @Test func adsResponseNoFillReasons() throws {
        let cases: [(entry: [String: Any], expected: VideoAdError.NoFillReason)] = [
            (Fixtures.noFillEntry("temporaryError", format: "pause", nextRequestAt: 38_000), .temporaryError),   // what it does not read is ignored
            (["format": "pause", "ads": []], .unknown),   // no reason
            (Fixtures.noFillEntry("brandNew", format: "pause"), .other("brandNew")),   // one the SDK does not know passes through
        ]
        for (entry, expected) in cases {
            let response = try decode(AdsResponse.self, ["enabled": true, "formats": [entry]])
            #expect(response.result(for: .pause)?.noFillReason == expected, "\(entry)")
        }
        #expect(VideoAdError.NoFillReason.other("brandNew").description == "brandNew", "the wire name survives for logs")
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

    @Test func adsResponseWithoutFormatsIsRejectedAndAFormatTheSDKDoesNotKnowIsIgnored() throws {
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause"]]]) }
        // A format added after this SDK shipped (a future `menu`), even twice or malformed: the rest stands.
        let menu: [String: Any] = ["format": "menu", "ads": [["id": "m1", "format": "menu"]]]
        let response = try decode(AdsResponse.self, ["enabled": true, "formats": [menu, Fixtures.filledEntry(Fixtures.ad(id: "p1")), menu, ["format": "menu", "ads": "junk"]]])
        #expect(response.result(for: .pause)?.ads.map(\.id) == ["p1"])
        #expect(response.result(for: .overlay) == nil && response.result(for: .linear) == nil)
    }

    @Test func oneInvalidAdLosesOnlyItsOwnFormat() throws {
        var linear = Fixtures.linearAd(id: "bad")
        linear["price"] = ["value": 2.0, "currency": "usd", "precision": "exact"]
        let response = try decode(AdsResponse.self, Fixtures.adsResponse(formats: ["overlay": Fixtures.overlayAd(id: "good"), "linear": linear]))
        #expect(response.result(for: .overlay)?.ads.map(\.id) == ["good"] && response.result(for: .overlay)?.dropped == [])
        let dropped = try #require(response.result(for: .linear))
        #expect(dropped.ads.isEmpty && dropped.noFillReason == .unknown, "a format with nothing valid left is a no-fill")
        #expect(dropped.dropped == ["price.currency"], "the failing field, for the report")
        // A field missing, a value of the wrong type, or not an object at all.
        var noId = Fixtures.ad(id: "x")
        noId.removeValue(forKey: "id")
        var badExpires = Fixtures.ad(id: "y")
        badExpires["expires"] = "soon"
        let pause = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [noId, badExpires, 7, Fixtures.ad(id: "z")], "noFillReason": "frequencyCap"]]])
        #expect(pause.result(for: .pause)?.ads.map(\.id) == ["z"] && pause.result(for: .pause)?.noFillReason == nil)
        #expect(pause.result(for: .pause)?.dropped == ["id", "expires", "ad"])
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

    @Test func anAdOfAnotherFormatThanItsResultIsDroppedAlone() throws {
        let stray = Fixtures.overlayAd(id: "o-in-pause")
        // The only ad, filed under the wrong format: a no-fill of reason unknown whatever the entry says, and not
        // filed under its own format either; another format is untouched.
        let onlyOther = try decode(AdsResponse.self, ["enabled": true, "formats": [
            ["format": "pause", "ads": [stray], "noFillReason": "frequencyCap"], Fixtures.filledEntry(Fixtures.linearAd()),
        ]])
        let misfiled = try #require(onlyOther.result(for: .pause))
        #expect(misfiled.ads.isEmpty && misfiled.dropped == ["format"] && misfiled.noFillReason == .unknown)
        #expect(onlyOther.result(for: .overlay) == nil)
        #expect(onlyOther.result(for: .linear)?.ads.map(\.id) == ["ad-i"])
        #expect(try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "overlay", "ads": [stray]]]]).result(for: .overlay)?.ads.map(\.id) == ["o-in-pause"])
    }

    @Test func aFormatListedTwiceFailsTheResponse() throws {
        let noFill: [String: Any] = ["format": "pause", "ads": [], "noFillReason": "frequencyCap"]
        let filled: [String: Any] = ["format": "pause", "ads": [Fixtures.ad()]]
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [noFill, filled]]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [filled, noFill]]) }
        let once = try decode(AdsResponse.self, ["enabled": true, "formats": [filled, ["format": "overlay", "ads": []]]])
        #expect(once.result(for: .pause)?.ads.count == 1)
    }

    @Test func anAdIdListedTwiceFailsTheResponseInEitherOrder() throws {
        let overlay = Fixtures.filledEntry(Fixtures.overlayAd(id: "same"))
        let pause = Fixtures.filledEntry(Fixtures.ad(id: "same"))
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [overlay, pause]]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [pause, overlay]]) }
        #expect(throws: DecodingError.self) { try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [Fixtures.ad(id: "same"), Fixtures.ad(id: "same")]]]]) }
        let distinct = try decode(AdsResponse.self, ["enabled": true, "formats": [overlay, Fixtures.filledEntry(Fixtures.ad(id: "other"))]])
        #expect(distinct.result(for: .pause)?.ads.map(\.id) == ["other"])
    }

    @Test func millisecondsMayBeFractionalAndAreRoundedToTheNearest() throws {
        var linear = Fixtures.linearAd(id: "l-frac")
        linear["expires"] = 30_000.4
        linear["duration"] = 15_023.5
        linear["skipOffset"] = 5000.2
        linear["tracking"] = [
            ["event": "progress", "url": "https://ads.test/p33", "offset": 4957.59],   // 33 % of 15 023 ms
            ["event": "progress", "url": "https://ads.test/p-neg", "offset": -1],
            ["event": "progress", "url": "https://ads.test/p-huge", "offset": 1e300],
            ["event": "progress", "url": "https://ads.test/p5", "offset": 5000],
            ["event": "progress", "url": "https://ads.test/p-str", "offset": "5000"],
            ["event": "progress", "url": "https://ads.test/p-obj", "offset": ["ms": 5000]],
            ["event": "progress", "url": "https://ads.test/p-bool", "offset": true],
            ["event": "start", "url": "https://ads.test/start"],
        ]
        let payload = try Fixtures.payload(linear)
        #expect(payload.expires == 30_000 && payload.details == .linear(duration: 15_024, skipOffset: 5000))
        #expect(payload.tracking.map(\.url) == ["https://ads.test/p33", "https://ads.test/p5", "https://ads.test/start"],
                "a negative, huge or non-numeric offset drops its entry, not the ad")
        #expect(payload.tracking.map(\.offset) == [4958, 5000, nil])
        var overlay = Fixtures.overlayAd(id: "o-frac")
        overlay["duration"] = 2999.5
        guard case .overlay(_, _, let duration) = try Fixtures.payload(overlay).details else { Issue.record("expected overlay"); return }
        #expect(duration == 3000)
        // Whole answers too: the response that failed on a fractional offset now decodes.
        let response = try decode(AdsResponse.self, Fixtures.adsResponse(linear))
        #expect(response.result(for: .linear)?.ads.map(\.id) == ["l-frac"])
        // Still refused: an entry broken otherwise, a non-finite or out-of-range duration.
        var noURL = Fixtures.linearAd(id: "l-nourl")
        noURL["tracking"] = [["event": "progress", "offset": 5000]]
        var huge = Fixtures.linearAd(id: "l-huge")
        huge["duration"] = 1e300
        for ad in [noURL, huge] {
            #expect(throws: DecodingError.self) { try Fixtures.payload(ad) }
        }
    }

    @Test func clearlyBrokenAdsAreRefused() throws {
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(id: "")) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(expires: 0)) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.ad(expires: -5)) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.overlayAd(duration: -1)) }
        #expect(throws: DecodingError.self) { try Fixtures.payload(Fixtures.linearAd(skipOffset: -1)) }
        #expect(try Fixtures.payload(Fixtures.linearAd(skipOffset: 0)).id == "ad-i", "a Close from the start is fine")
        // Negative before rounding: -0.4 rounds to 0 and is still broken.
        var almostZero = Fixtures.overlayAd()
        almostZero["duration"] = -0.4
        #expect(throws: DecodingError.self) { try Fixtures.payload(almostZero) }
        // A linear video of no length: nothing to play.
        for duration in [0, 0.4, -1000] as [Double] {
            var linear = Fixtures.linearAd()
            linear["duration"] = duration
            #expect(throws: DecodingError.self, "\(duration)") { try Fixtures.payload(linear) }
        }
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
        #expect(sizes == [AdPayload.Size(width: 300, height: 250, isScalable: false)])
        let unsaid = try Fixtures.payload(Fixtures.ad(size: ["width": 300, "height": 250]))
        guard case .pause(_, let defaulted) = unsaid.details else { Issue.record("expected pause"); return }
        #expect(defaulted.first?.isScalable == true, "absent is scalable")
    }

    @Test func theFrameURLMustBeAbsoluteWithAHost() throws {
        for ok in ["https://server.kontext.so/frame/ad-1", "http://localhost:5175/frame/ad-1", "kontext-test://frames/frame/ad-1",
                   "https://[::1]:5175/frame/ad-1", "https://frames.test/frame%20ad?q=1#x"] {
            #expect(try Fixtures.payload(Fixtures.ad(frameURL: ok)).rendering == .frame(URL(string: ok)!))
        }
        for bad in ["frame/ad-1", "/frame/ad-1", "file:///etc/passwd", "file://localhost/etc/passwd", "javascript:alert(1)", "data:text/html,hi", "blob:https://x/y", "about:blank",
                    "ftp://frames.test/frame", "ws://frames.test/frame", "myapp://frames/frame", "https://frames.test:0/frame", "https://frames.test:99999/frame",
                    // Not a URL as written, though Foundation would encode it into one.
                    "https://frames.test/fr ame", "https://fr ames.test/frame", "https://frames.test/frame?q=a\u{00A0}b", "https://frames.test/[frame]",
                    "https://frames.test/frame%zz", "https://frames.test/frame%2", "https://frames.test/a|b", "https://frames.test/a\\b"] {
            #expect(throws: DecodingError.self, "\(bad)") { try Fixtures.payload(Fixtures.ad(frameURL: bad)) }
        }
    }

    @Test func aPriceIsAFiniteNonNegativeCPMInAThreeLetterCurrency() throws {
        func price(_ fields: String) throws -> AdPayload.Price {
            try JSONDecoder().decode(AdPayload.Price.self, from: Data("{\(fields), \"precision\": \"exact\"}".utf8))
        }
        #expect(try price(#""value": 7.5, "currency": "USD""#).value == 7.5)
        #expect(try price(#""value": 0, "currency": "EUR""#).value == 0)
        for bad in [#""value": 1e400, "currency": "USD""#, #""value": -1, "currency": "USD""#, #""value": 1, "currency": "usd""#,
                    #""value": 1, "currency": "US""#, #""value": 1, "currency": "DOLLARS""#, #""value": 1, "currency": "U$D""#,
                    "\"value\": 1, \"currency\": \"A\u{0338}BC\"", "\"value\": 1, \"currency\": \"US\u{200D}D\""] {
            #expect(throws: DecodingError.self, "\(bad)") { try price(bad) }
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

    @Test func overlayAd() throws {
        let ad = try Fixtures.payload(Fixtures.ad(format: "overlay", position: "bottom", duration: 6000))
        #expect(ad.format == .overlay)
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
        // A part of the wrong type is no main-creative beacon: the ad is malformed. Null is absent.
        var numbered = Fixtures.linearAd()
        numbered["tracking"] = [["event": "click", "url": "https://ads.test/end", "part": 2]]
        #expect(throws: DecodingError.self) { try Fixtures.payload(numbered) }
        numbered["tracking"] = [["event": "click", "url": "https://ads.test/end", "part": NSNull()]]
        #expect(try Fixtures.payload(numbered).tracking.first?.part == nil)
    }

    @Test func anAdWithoutAVastUrlDecodes() throws {
        var ad = Fixtures.ad()
        ad["vastUrl"] = nil
        #expect(try Fixtures.payload(ad).id == "ad-1", "the SDK never reads it; it is for players that render VAST")
    }

    @Test func onlyAManualTriggerIsTaken() throws {
        // The SDK does not act on a trigger yet: a window, even a valid one, is refused rather than shown at any time.
        for trigger: [String: Any] in [["kind": "window", "from": 4000, "to": 10_000], ["kind": "window", "from": 4000], ["kind": "timer"]] {
            do {
                _ = try Fixtures.payload(Fixtures.ad(format: "overlay", trigger: trigger, position: "bottom", duration: 6000))
                Issue.record("expected \(trigger) to fail the ad")
            } catch DecodingError.dataCorrupted(let context) {
                #expect(context.codingPath.map(\.stringValue) == ["trigger", "kind"], "\(trigger)")
            }
        }
        #expect(try Fixtures.payload(Fixtures.ad(trigger: ["kind": "manual"])).id == "ad-1")
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
        // A malformed second ad is dropped alone.
        var broken = Fixtures.ad(id: "ad-2")
        broken["sizes"] = []
        let kept = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [Fixtures.ad(), broken]]]])
        #expect(kept.result(for: .pause)?.ads.map(\.id) == ["ad-1"] && kept.result(for: .pause)?.dropped == ["sizes"])
        // An ad filed under the wrong format (its own `format` is not its entry's) is a malformed ad: it alone is
        // dropped, the rest of the answer counts.
        let withOther = try decode(AdsResponse.self, ["enabled": true, "formats": [["format": "pause", "ads": [Fixtures.ad(), Fixtures.overlayAd()]]]])
        #expect(withOther.result(for: .pause)?.ads.map(\.id) == ["ad-1"] && withOther.result(for: .pause)?.dropped == ["format"])
        #expect(withOther.result(for: .pause)?.noFillReason == nil)
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
        #expect(throws: DecodingError.self, "a isScalable flag of the wrong type is a malformed size") {
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

    @Test func aSkanIdSentAsAWholeFloatIsTheIntegerAndAFractionIsNoId() throws {
        for (raw, expected) in [(1_234_567_890.0, "1234567890"), (42, "42")] as [(Double, String)] {
            var ad = Fixtures.ad()
            var skan = Fixtures.skan()
            skan["itunesItem"] = raw
            ad["attribution"] = ["skan": skan]
            #expect(try Fixtures.descriptor(ad).skan?.itunesItem == expected, "\(raw)")
        }
        var fraction = Fixtures.ad()
        var skan = Fixtures.skan()
        skan["itunesItem"] = 1.5
        fraction["attribution"] = ["skan": skan]
        #expect(try Fixtures.descriptor(fraction).skan == nil, "1.5 is no app id: no attribution")
    }

    @Test func aSizeOutOfRangeIsReportedAtItsOwnKey() throws {
        for (size, key) in [(["width": 0, "height": 50], "width"), (["width": 320, "height": 0], "height")] {
            do {
                _ = try decode(AdPayload.Size.self, size)
                Issue.record("expected a refusal for \(size)")
            } catch DecodingError.dataCorrupted(let context) {
                #expect(context.codingPath.last?.stringValue == key, "\(size)")
            }
        }
    }

    @Test func anEmptyReasonIsUnknown() throws {
        #expect(AdsResponse.reason("") == AdsResponse.unknownReason && AdsResponse.reason("  ") == AdsResponse.unknownReason)
        #expect(AdsResponse.reason(nil) == AdsResponse.unknownReason && AdsResponse.reason("publisherDisabled") == "publisherDisabled")
        #expect(VideoAdError.NoFillReason("") == .unknown && VideoAdError.NoFillReason(" ") == .unknown)
        #expect(VideoAdError.NoFillReason("custom") == .other("custom"))
    }
}
