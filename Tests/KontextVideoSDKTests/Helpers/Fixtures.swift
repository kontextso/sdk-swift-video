import Foundation
@testable import KontextVideoSDK

/// Wire payloads as the ad server sends them, with knobs for what a test varies.
enum Fixtures {
    static let frameOrigin = "kontext-test://frames"

    /// `video`: the creative's events; `nonLinear`: an overlay or pause ad's `overlayViewDuration`.
    static func tracking(video: Bool, nonLinear: Bool = true, origin: String = "https://ads.test", adId: String = "ad-1") -> [[String: Any]] {
        let url = { (event: String, extra: String) -> String in
            "\(origin)/events/\(adId)/\(event)?\(extra.isEmpty ? "" : extra + "&")cb=[CACHEBUSTING]&fid=[KONTEXT_FIREID]&ts=[TIMESTAMP]&cph=[MEDIAPLAYHEAD]"
        }
        var entries: [[String: Any]] = [
            ["event": "loaded", "url": url("loaded", "")],
            ["event": "impression", "url": url("impression", "")],
            ["event": "creativeView", "url": url("creativeView", "")],
            ["event": "viewable", "url": url("viewable", "")],
            ["event": "notViewable", "url": url("notViewable", "")],
            ["event": "viewUndetermined", "url": url("viewUndetermined", "")],
            ["event": "click", "url": url("click", "")],
            ["event": "close", "url": url("close", "")],
            ["event": "error", "url": url("error", "code=[ERRORCODE]&aph=[ADPLAYHEAD]")],
            ["event": "iconView", "url": url("iconView", "")],
            ["event": "iconClick", "url": url("iconClick", "")],
            ["event": "notUsed", "url": url("notUsed", "reason=[KONTEXT_REASON]&wp=[KONTEXT_WINNINGPRICE]&winner=[KONTEXT_WINNER]")],
        ]
        if video {
            entries += [
                ["event": "start", "url": url("start", "")],
                ["event": "firstQuartile", "url": url("firstQuartile", "")],
                ["event": "midpoint", "url": url("midpoint", "")],
                ["event": "thirdQuartile", "url": url("thirdQuartile", "")],
                ["event": "complete", "url": url("complete", "")],
                ["event": "progress", "url": url("progress", "offset=5000"), "offset": 5000],
                ["event": "skip", "url": url("skip", "aph=[ADPLAYHEAD]")],
                ["event": "pause", "url": url("pause", "aph=[ADPLAYHEAD]")],
                ["event": "resume", "url": url("resume", "aph=[ADPLAYHEAD]")],
                ["event": "mute", "url": url("mute", "")],
                ["event": "unmute", "url": url("unmute", "")],
                ["event": "creativeView", "url": url("creativeView", "part=endCard"), "part": "endCard"],
                ["event": "click", "url": url("click", "part=endCard"), "part": "endCard"],
            ]
        }
        if nonLinear {
            entries.append(["event": "overlayViewDuration", "url": url("overlayViewDuration", "ovd=[KONTEXT_VIEWDURATION]")])
        }
        return entries
    }

    static func ad(
        id: String = "ad-1",
        format: String = "pause",
        creative: String = "image",
        expires: Int = 3_600_000,
        trigger: [String: Any] = ["kind": "manual"],
        position: String? = "top",
        size: [String: Any]? = ["width": 300, "height": 300, "scalable": true, "maintainAspectRatio": true],
        moreSizes: [[String: Any]] = [],
        duration: Int? = nil,
        skipOffset: Int? = nil,
        frameURL: String? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var ad: [String: Any] = [
            "id": id,
            "format": format,
            "creative": creative,
            "trigger": trigger,
            "price": ["model": "cpm", "value": 7.5, "currency": "USD", "precision": "exact"],
            "expires": expires,
            "rendering": ["kind": "frame", "url": frameURL ?? "\(frameOrigin)/frame/\(id)"],
            "tracking": tracking(video: creative == "video", nonLinear: format != "linear", adId: id),
            "vastUrl": "https://ads.test/v2/video/ads/\(id)/vast",
        ]
        if let position { ad["position"] = position }
        if let size { ad["sizes"] = [size] + moreSizes }
        if let duration { ad["duration"] = duration }
        if let skipOffset { ad["skipOffset"] = skipOffset }
        extra.forEach { ad[$0.key] = $0.value }
        return ad
    }

    static func overlayAd(id: String = "ad-o", duration: Int = 6000, position: String = "bottom", creative: String = "image") -> [String: Any] {
        ad(id: id, format: "overlay", creative: creative, position: position, size: ["width": 320, "height": 90, "scalable": true, "maintainAspectRatio": true], duration: duration)
    }

    static func linearAd(id: String = "ad-i", duration: Int = 10_000, skipOffset: Int? = 5000) -> [String: Any] {
        ad(id: id, format: "linear", creative: "video", position: nil, size: nil, duration: duration, skipOffset: skipOffset)
    }

    /// Every format answered: `ad` for its own format, a no-fill for the others.
    static func adsResponse(_ ad: [String: Any]) -> [String: Any] {
        adsResponse(formats: [ad["format"] as? String ?? "pause": ad])
    }

    /// Every format answered, in the server's order: an ad (or a no-fill entry) from `entries` by format
    /// name, `noAdMatch` for the rest. An entry is an ad (it has an `id`) or a whole entry (`noFillEntry`).
    static func adsResponse(formats entries: [String: [String: Any]]) -> [String: Any] {
        let formats = ["overlay", "pause", "linear"].map { format -> [String: Any] in
            guard let entry = entries[format] else { return noFillEntry(format: format) }
            return entry["id"] == nil ? entry : ["format": format, "ads": [entry]]
        }
        return ["enabled": true, "formats": formats]
    }

    /// Every format a no-fill with `reason`.
    static func noFill(_ reason: String = "noAdMatch") -> [String: Any] {
        ["enabled": true, "formats": ["overlay", "pause", "linear"].map { noFillEntry(reason, format: $0) }]
    }

    static func noFillEntry(_ reason: String = "noAdMatch", format: String = "pause", nextRequestAt: Int? = nil) -> [String: Any] {
        var entry: [String: Any] = ["format": format, "ads": [], "noFillReason": reason]
        if let nextRequestAt { entry["nextRequestAt"] = nextRequestAt }
        return entry
    }

    static func filledEntry(_ ad: [String: Any]) -> [String: Any] {
        ["format": ad["format"] as? String ?? "pause", "ads": [ad]]
    }

    static func initEnabled(reportDebug: Bool = false, reportErrors: Bool? = nil) -> [String: Any] {
        var body: [String: Any] = ["enabled": true, "reportDebug": reportDebug]
        if let reportErrors { body["reportErrors"] = reportErrors }
        return body
    }

    static func disabled(_ reason: String = "publisherDisabled") -> [String: Any] {
        ["enabled": false, "disabledReason": reason]
    }

    static func errors(_ code: String, title: String = "bad", detail: String? = nil, status: Int = 400) -> [String: Any] {
        var item: [String: Any] = ["status": "\(status)", "code": code, "title": title]
        if let detail { item["detail"] = detail }
        return ["errors": [item]]
    }

    static func payload(_ ad: [String: Any]) throws -> AdPayload {
        try JSONDecoder().decode(AdPayload.self, from: JSONSerialization.data(withJSONObject: ad))
    }

    /// The SKAdNetwork payload of an app-install ad, the Video API's example values; `fidelities` says
    /// which entries the network signed (1: the click, 0: the view-through impression).
    static func skan(itunesItem: String = "1521454264", fidelities: [Int] = [1, 0]) -> [String: Any] {
        [
            "version": "4.0",
            "network": "mp7rpxwdrx.adattributionkit",
            "itunesItem": itunesItem,
            "sourceApp": "6479835900",
            "sourceIdentifier": "4021",
            "fidelities": fidelities.map { ["fidelity": $0, "nonce": "3f2c1a9e-000\($0)", "timestamp": "1790850000000", "signature": "MEUCIQ\($0)"] },
        ]
    }

    /// `ad` with the attribution of an app-install ad whose advertised app is `itunesItem`.
    static func installAd(_ ad: [String: Any], itunesItem: String, fidelities: [Int] = [1, 0]) -> [String: Any] {
        var ad = ad
        ad["attribution"] = ["skan": skan(itunesItem: itunesItem, fidelities: fidelities)]
        return ad
    }

    /// The answer as a bid takes it, received now.
    static func descriptor(_ ad: [String: Any]) throws -> AdDescriptor {
        AdDescriptor(payload: try payload(ad), receivedAt: Environment.now())
    }

    static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
}
