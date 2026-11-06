import Foundation
@testable import KontextVideoSDK
import Testing

/// `FrameMessage.parse` as a table: the envelope (an object, this ad's id, a type, the 1 MB limit) and every field
/// read as the protocol reads it, with no rule applied.
@Suite
struct FrameMessageTests {
    private func parse(_ raw: Any, limit: Int = 10_000) -> FrameMessage? {
        FrameMessage.parse(raw, adId: "ad-1", playheadLimitMs: limit)
    }

    @Test func aBrokenEnvelopeIsNil() {
        let head = "{\"adId\":\"ad-1\",\"type\":\"ad.loaded\",\"padding\":\"", tail = "\"}"
        let atLimit = head + String(repeating: "x", count: FrameMessage.maxMessageBytes - head.utf8.count - tail.utf8.count) + tail
        let cases: [(Any, Bool)] = [
            (["adId": "ad-1", "type": "ad.loaded"], true),
            ("{\"adId\":\"ad-1\",\"type\":\"ad.loaded\"}", true),
            (atLimit, true),
            (head + "x" + atLimit.dropFirst(head.utf8.count), false),
            (["adId": "ad-2", "type": "ad.loaded"], false),
            (["type": "ad.loaded"], false),
            (["adId": "ad-1"], false),
            (["adId": "ad-1", "type": 7], false),
            ("not json", false),
            ("[1, 2]", false),
            (42, false),
            // An object's text within the string's budget, and over it.
            (["adId": "ad-1", "type": "ad.click", "url": String(repeating: "x", count: FrameMessage.maxMessageBytes / 2)], true),
            (["adId": "ad-1", "type": "ad.click", "url": String(repeating: "x", count: FrameMessage.maxMessageBytes + 1)], false),
        ]
        for (index, (raw, parses)) in cases.enumerated() {
            #expect((parse(raw) != nil) == parses, "case \(index)")
        }
    }

    @Test func thePlayheadIsClampedAndRounded() {
        let cases: [(Any?, Int)] = [
            (nil, 0), (1500, 1500), (1499.6, 1500), (1499.4, 1499), (-5, 0), (20_000, 10_000),
            (Double.infinity, 0), ("100", 0),
        ]
        for (raw, expected) in cases {
            var body: [String: Any] = ["adId": "ad-1", "type": "video.start"]
            body["playhead"] = raw
            #expect(parse(body)?.playheadMs == expected, "\(String(describing: raw))")
        }
    }

    @Test func theFieldsAreReadAsSent() throws {
        let message = try #require(parse([
            "adId": "ad-1", "type": "ad.click", "url": "https://a.test", "fallbackUrl": "https://b.test",
            "area": "endCard", "purpose": "adChoices", "reason": "userClose", "code": 403, "offset": 2500.5,
        ]))
        #expect(message.type == "ad.click")
        #expect(message.url == "https://a.test" && message.fallbackUrl == "https://b.test")
        #expect(message.area == "endCard" && message.purpose == "adChoices" && message.reason == "userClose")
        #expect(message.code == 403 && message.offset == 2500.5)
        let bare = try #require(parse(["adId": "ad-1", "type": "ad.close", "url": 5, "offset": "10", "code": "403"]))
        #expect(bare.url == nil && bare.offset == nil && bare.code == nil, "a field of the wrong type is absent")
        // JSONSerialization gives true and false as NSNumbers: they are not numbers, in a string or an object body.
        let json = #"{"adId":"ad-1","type":"ad.error","playhead":true,"offset":false,"code":true}"#
        let object: [String: Any] = ["adId": "ad-1", "type": "ad.error", "playhead": true, "offset": false, "code": true]
        for raw in [json as Any, object as Any] {
            let booleans = try #require(FrameMessage.parse(raw, adId: "ad-1", playheadLimitMs: 60_000))
            #expect(booleans.playheadMs == 0 && booleans.offset == nil && booleans.code == nil, "\(raw)")
        }
    }
}
