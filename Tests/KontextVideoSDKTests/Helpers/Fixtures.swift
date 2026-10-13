import Foundation
@testable import KontextVideoSDK

/// Wire payloads as the ad server sends them, with knobs for what a test varies.
enum Fixtures {
    static let frameOrigin = "kontext-test://frames"

    static func tracking(video: Bool, origin: String = "https://ads.test", adId: String = "ad-1") -> [[String: Any]] {
        let url = { (event: String, extra: String) -> String in
            "\(origin)/events/\(adId)/\(event)?\(extra.isEmpty ? "" : extra + "&")cb=[CACHEBUSTING]&fid=[FIREID]&ts=[TIMESTAMP]&cph=[CONTENTPLAYHEAD]"
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
        } else {
            entries.append(["event": "overlayViewDuration", "url": url("overlayViewDuration", "")])
        }
        return entries
    }

    static func ad(
        id: String = "ad-1",
        placementId: String = "pause",
        format: String = "pause",
        creative: String = "image",
        expires: Int = 3_600_000,
        trigger: [String: Any] = ["kind": "manual"],
        position: String? = "top",
        size: [String: Any]? = ["width": 300, "height": 300, "scalable": true, "maintainAspectRatio": true],
        duration: Int? = nil,
        skipOffset: Int? = nil,
        reward: [String: Any]? = nil,
        frameURL: String? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var ad: [String: Any] = [
            "id": id,
            "placementId": placementId,
            "format": format,
            "creative": creative,
            "trigger": trigger,
            "price": ["model": "cpm", "value": 7.5, "currency": "USD", "precision": "exact"],
            "expires": expires,
            "rendering": ["kind": "frame", "url": frameURL ?? "\(frameOrigin)/frame/\(id)"],
            "tracking": tracking(video: creative == "video", adId: id),
            "vastUrl": "https://ads.test/v2/video/ads/\(id)/vast",
        ]
        if let position { ad["position"] = position }
        if let size { ad["size"] = size }
        if let duration { ad["duration"] = duration }
        if let skipOffset { ad["skipOffset"] = skipOffset }
        if let reward { ad["reward"] = reward }
        extra.forEach { ad[$0.key] = $0.value }
        return ad
    }

    static func overlayAd(id: String = "ad-o", placementId: String = "overlay", duration: Int = 6000, position: String = "bottom") -> [String: Any] {
        ad(id: id, placementId: placementId, format: "overlay", position: position, size: ["width": 320, "height": 90, "scalable": true, "maintainAspectRatio": true], duration: duration)
    }

    static func linearAd(id: String = "ad-i", placementId: String = "linear", duration: Int = 10_000, skipOffset: Int? = 5000, reward: [String: Any]? = nil) -> [String: Any] {
        ad(id: id, placementId: placementId, format: "linear", creative: "video", position: nil, size: nil, duration: duration, skipOffset: skipOffset, reward: reward)
    }

    static func adsResponse(_ ad: [String: Any], nextRequestAt: Int? = nil) -> [String: Any] {
        var response: [String: Any] = ["enabled": true, "ad": ad]
        if let nextRequestAt { response["nextRequestAt"] = nextRequestAt }
        return response
    }

    static func noFill(_ reason: String = "noAdMatch", retryAfter: Int? = nil, nextRequestAt: Int? = nil) -> [String: Any] {
        var response: [String: Any] = ["enabled": true, "noFillReason": reason]
        if let retryAfter { response["retryAfter"] = retryAfter }
        if let nextRequestAt { response["nextRequestAt"] = nextRequestAt }
        return response
    }

    static func initEnabled(reportDebug: Bool = false) -> [String: Any] {
        ["enabled": true, "reportDebug": reportDebug]
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

    static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
}
