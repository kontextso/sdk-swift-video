import Foundation
@testable import KontextVideoSDK
import Testing

/// The beacon firer: every entry once, selected by name, part and offset, with the VAST macros filled in.
extension SerialSuites {
@Suite
@MainActor
struct TrackerTests {
    private let server = StubServer()

    init() {
        SDKHarness.reset()
        server.install()
        server.on("/events/", .empty())
    }

    private func makeTracker(video: Bool = true) throws -> Tracker {
        let entries = try Fixtures.payload(video ? Fixtures.linearAd(id: "ad-1") : Fixtures.ad(id: "ad-1")).tracking
        return Tracker(adId: "ad-1", entries: entries)
    }

    /// The beacons once `expected` arrived, plus a short settle so a stray extra one would show.
    private func fired(_ expected: Int) async -> [(adId: String, event: String, query: [String: String])] {
        _ = await waitUntil(5) { self.server.beacons.count >= expected }
        await sleepMs(50)
        return server.beacons
    }

    @Test func firesEachEntryOnce() async throws {
        let tracker = try makeTracker()
        tracker.fire("impression")
        tracker.fire("impression")
        tracker.fire("impression")
        let beacons = await fired(1)
        #expect(beacons.map(\.event) == ["impression"])
    }

    @Test func clicksAndPlaybackTogglesFireEveryTimeWithTheirOwnFireId() async throws {
        let tracker = try makeTracker()
        // The contract's list, written out: derived from `Tracker.repeatable`, a name dropped there would pass.
        let repeatable = ["click", "mute", "pause", "resume", "unmute"]
        var ids: [String: [String]] = [:]
        for event in repeatable {
            ids[event] = [tracker.fire(event), tracker.fire(event)]
        }
        tracker.fire("start")
        tracker.fire("start")
        let beacons = await fired(repeatable.count * 2 + 1)
        for event in repeatable {
            let fids = beacons.filter { $0.event == event && $0.query["part"] == nil }.map { $0.query["fid"] ?? "" }
            #expect(Set(fids) == Set(ids[event] ?? []) && fids.count == 2, "\(event) fires each time, each with its own fire id")
        }
        #expect(beacons.filter { $0.event == "start" }.count == 1, "start is once")
        let second = ids["click"]?.last ?? ""
        let through = tracker.clickThrough(URL(string: "https://ads.test/redirect?fid=%5BKONTEXT_FIREID%5D&q=%5Bkept%5D")!, fireId: second)
        #expect(through.query == "fid=\(second)&q=%5Bkept%5D", "the click-through carries its click's fire id; a bracket that is no macro survives")
    }

    @Test func everyFireCarriesItsOwnFireIdSharedByItsURLs() async throws {
        let entry = { (event: String, copy: Int) in
            AdPayload.TrackingEvent(event: event, url: "https://ads.test/events/ad-1/\(event)?copy=\(copy)&fid=[KONTEXT_FIREID]", offset: nil, part: nil)
        }
        let tracker = Tracker(adId: "ad-1", entries: [entry("impression", 1), entry("impression", 2), entry("click", 1), entry("click", 2), entry("click", 3)])
        let impression = tracker.fire("impression")
        let click = tracker.fire("click")
        let beacons = await fired(5)
        #expect(beacons.filter { $0.event == "impression" }.map { $0.query["fid"] } == [impression, impression], "one occurrence, one id across its URLs")
        #expect(beacons.filter { $0.event == "click" }.map { $0.query["fid"] } == [click, click, click])
        #expect(impression != click && UUID(uuidString: impression) != nil, "a different UUID per occurrence")
    }

    @Test func firesTheGetWithTheSDKsTimeoutAndNoCache() async throws {
        let tracker = try makeTracker()
        tracker.fire("loaded")
        _ = await fired(1)
        let request = try #require(server.requests(to: "/events/").first?.request)
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 10)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func selectsByPart() async throws {
        let tracker = try makeTracker()
        tracker.fire("creativeView")
        tracker.fire("creativeView", part: "endCard")
        tracker.fire("click", part: "endCard")
        let beacons = await fired(3)
        let seen = beacons.map { "\($0.event)/\($0.query["part"] ?? "main")" }.sorted()
        #expect(seen == ["click/endCard", "creativeView/endCard", "creativeView/main"], "whatever order they arrive in")
    }

    @Test func selectsProgressByOffset() async throws {
        let tracker = try makeTracker()
        tracker.fire("progress", offset: 4000)
        tracker.fire("progress", offset: 5000)
        tracker.fire("progress", offset: 5000)
        let beacons = await fired(1)
        #expect(beacons.map(\.event) == ["progress"])
        #expect(beacons[0].query["offset"] == "5000")
    }

    @Test func progressFiresEveryCheckpointPassedOnceEachWithItsOwnFireId() async throws {
        let entry = { (offset: Int) in
            AdPayload.TrackingEvent(event: "progress", url: "https://ads.test/events/ad-1/progress?offset=\(offset)&fid=[KONTEXT_FIREID]", offset: offset, part: nil)
        }
        let tracker = Tracker(adId: "ad-1", entries: [entry(5000), entry(10_000), entry(15_000)])
        tracker.fireProgress(upTo: 4999)
        tracker.fireProgress(upTo: 10_200)   // the page skipped 5000 and rounded 10 000 up
        tracker.fireProgress(upTo: 10_200)
        let beacons = await fired(2)
        #expect(beacons.compactMap { Int($0.query["offset"] ?? "") }.sorted() == [5000, 10_000], "both passed checkpoints, once each, whatever order they arrive in; 15 000 waits")
        #expect(Set(beacons.map { $0.query["fid"] }).count == 2, "separate occurrences, separate fire ids")
    }

    @Test func unknownEventsFireNothing() async throws {
        let tracker = try makeTracker(video: false)
        tracker.fire("rewind")
        tracker.fire("start", part: nil)
        #expect(await fired(0).isEmpty, "an image creative has no start entry; rewind is not in the list")
    }

    @Test func substitutesEveryMacro() async throws {
        let tracker = try makeTracker()
        tracker.contentPlayhead = { 3661.25 }
        tracker.adPlayhead = 7_500
        let before = Date()
        tracker.fire("error", errorCode: 405)
        let beacon = try #require(await fired(1).first)
        let after = Date()
        #expect(beacon.query["code"] == "405")
        #expect(beacon.query["cph"] == "01:01:01.250", "[MEDIAPLAYHEAD] is HH:MM:SS.mmm")
        #expect(beacon.query["aph"] == "00:00:07.500", "[ADPLAYHEAD] is HH:MM:SS.mmm")
        let cb = try #require(beacon.query["cb"])
        #expect(cb.count == 8 && Int(cb) != nil, "[CACHEBUSTING] is 8 digits")
        let ts = try #require(beacon.query["ts"])
        #expect(ts.contains("T") && ts.contains("."), "[TIMESTAMP] is ISO 8601 with milliseconds: \(ts)")
        #expect(ts.hasSuffix("Z") || ts.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) != nil, "in the device's zone: \(ts)")
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try #require(parser.date(from: ts))
        #expect(parsed >= before.addingTimeInterval(-0.001) && parsed <= after, "the moment of firing, between the call and its arrival")
    }

    @Test func playheadsAreWholeMillisecondsNeverOneShort() async throws {
        let tracker = try makeTracker()
        tracker.contentPlayhead = { 9.806 }   // 9.80599… in binary: truncating the fraction gives .805
        tracker.adPlayhead = 59_999
        tracker.fire("error", errorCode: 400)
        let beacon = try #require(await fired(1).first)
        #expect(beacon.query["cph"] == "00:00:09.806")
        #expect(beacon.query["aph"] == "00:00:59.999")
    }

    @Test func aNonsensePlayheadIsClampedNotCrashed() async throws {
        #expect(Tracker.playhead(seconds: .infinity) == "00:00:00.000")
        #expect(Tracker.playhead(seconds: .nan) == "00:00:00.000")
        #expect(Tracker.playhead(seconds: -5) == "00:00:00.000")
        #expect(Tracker.playhead(seconds: TimeInterval(Int.max) / 1000) == "87600:00:00.000", "ten years, not a trap")
        #expect(Tracker.playhead(seconds: 1e300) == "87600:00:00.000")
        #expect(Tracker.playhead(seconds: 3661.25) == "01:01:01.250")
        let tracker = try makeTracker()
        tracker.adPlayhead = Int.max
        tracker.contentPlayhead = { .infinity }
        tracker.fire("error", errorCode: 400)
        let beacon = try #require(await fired(1).first)
        #expect(beacon.query["aph"] == "87600:00:00.000" && beacon.query["cph"] == "00:00:00.000")
    }

    @Test func theDeprecatedContentPlayheadIsFilledLikeMediaPlayhead() async throws {
        let tracker = Tracker(adId: "ad-1", entries: [
            AdPayload.TrackingEvent(event: "impression", url: "https://ads.test/events/ad-1/impression?old=[CONTENTPLAYHEAD]&new=[MEDIAPLAYHEAD]&x=[KONTEXT_UNKNOWN]", offset: nil, part: nil),
        ])
        var reads = 0
        tracker.contentPlayhead = { reads += 1; return TimeInterval(reads) }   // advances on every read
        tracker.fire("impression")
        let beacon = try #require(await fired(1).first)
        #expect(beacon.query["old"] == "00:00:01.000" && beacon.query["new"] == "00:00:01.000", "both names, one moment")
        #expect(reads == 1, "read once per beacon")
        #expect(beacon.query["x"] == "[KONTEXT_UNKNOWN]", "a macro the SDK does not know stays in place")
        let raw = try #require(server.requests(to: "/events/").first?.request.url?.absoluteString)
        #expect(raw.contains("x=%5BKONTEXT_UNKNOWN%5D") && !raw.contains("%25"), "its brackets are encoded, so nothing else is re-encoded: \(raw)")
    }

    @Test func aPartlyEncodedPlayheadMacroIsStillFilled() async throws {
        let tracker = Tracker(adId: "ad-1", entries: [
            AdPayload.TrackingEvent(event: "impression", url: "https://ads.test/events/ad-1/impression?new=%5BMEDIAPLAYHEAD]&old=[CONTENTPLAYHEAD%5D", offset: nil, part: nil),
        ])
        var reads = 0
        tracker.contentPlayhead = { reads += 1; return 61.5 }
        tracker.fire("impression")
        let beacon = try #require(await fired(1).first)
        #expect(beacon.query["new"] == "00:01:01.500", "an encoded opening bracket only")
        #expect(beacon.query["old"] == "00:01:01.500", "an encoded closing bracket only")
        #expect(reads == 1, "read once for both")
    }

    @Test func cacheBustingIsEightRandomDigitsPerBeacon() async throws {
        // The IAB registry asks for an 8-digit random number; two may collide, so only the shape is checked.
        let tracker = try makeTracker()
        tracker.fire("start")
        tracker.fire("firstQuartile")
        let beacons = await fired(2)
        #expect(beacons.count == 2)
        for cb in beacons.compactMap({ $0.query["cb"] }) {
            #expect(cb.count == 8 && cb.allSatisfy(\.isASCII) && Int(cb) != nil, "\(cb)")
        }
    }

    @Test func theContentPlayheadIsNotReadWhenNoURLAsksForIt() async throws {
        let tracker = Tracker(adId: "ad-1", entries: [
            AdPayload.TrackingEvent(event: "impression", url: "https://ads.test/events/ad-1/impression?cb=[CACHEBUSTING]", offset: nil, part: nil),
        ])
        var reads = 0
        tracker.contentPlayhead = { reads += 1; return 1 }
        tracker.fire("impression")
        _ = await fired(1)
        #expect(reads == 0)
    }

    @Test func progressAtSharedAndUnsortedOffsetsFiresEachCheckpointOnceWithOneIdPerCheckpoint() async throws {
        let entry = { (offset: Int, copy: Int) in
            AdPayload.TrackingEvent(event: "progress", url: "https://ads.test/events/ad-1/progress?offset=\(offset)&copy=\(copy)&fid=[KONTEXT_FIREID]", offset: offset, part: nil)
        }
        let tracker = Tracker(adId: "ad-1", entries: [entry(10_000, 1), entry(5000, 1), entry(10_000, 2), entry(15_000, 1)])
        tracker.fireProgress(upTo: 12_000)
        tracker.fireProgress(upTo: 12_000)
        let beacons = await fired(3)
        #expect(beacons.count == 3, "5000 once, 10 000 for both its URLs, 15 000 not yet")
        let tenK = beacons.filter { $0.query["offset"] == "10000" }
        #expect(tenK.count == 2 && Set(tenK.map { $0.query["fid"] }).count == 1, "one checkpoint, one fire id across its URLs")
        #expect(beacons.filter { $0.query["offset"] == "5000" }.count == 1)
    }

    @Test func macrosAreURLEncoded() async throws {
        let tracker = try makeTracker()
        tracker.fire("loaded")
        _ = await fired(1)
        let raw = try #require(server.requests(to: "/events/").first?.request.url?.absoluteString)
        #expect(raw.range(of: "cph=00%3A00%3A00.000") != nil, "colons in playheads are escaped")
        let ts = try #require(URLComponents(string: raw)?.percentEncodedQueryItems?.first { $0.name == "ts" }?.value)
        #expect(ts.contains("%3A") && !ts.contains(":"), "the timestamp's colons are escaped: \(ts)")
    }

    @Test func aWinnerAndAPriceAreEncodedAsOneQueryValue() async throws {
        let tracker = try makeTracker()
        tracker.fire("notUsed", notUsed: Tracker.NotUsed(.outbid(winningPrice: 1e+20, winner: "Ad/Net;work?x=1&y=2 +")))
        let beacon = try #require(await fired(1).first)
        #expect(beacon.query["winner"] == "Ad/Net;work?x=1&y=2 +", "decoded, the name is intact")
        #expect(beacon.query["wp"] == "1e+20")
        let raw = try #require(server.requests(to: "/events/").first?.request.url?.absoluteString)
        #expect(raw.contains("winner=Ad%2FNet%3Bwork%3Fx%3D1%26y%3D2%20%2B") && raw.contains("wp=1e%2B20"), "nothing a parser could take for a delimiter: \(raw)")
    }

    @Test func invalidURLsAreSkippedWithoutStoppingOthers() async throws {
        let invalid = AdPayload.TrackingEvent(event: "impression", url: "", offset: nil, part: nil)   // the one string URL(string:) still refuses
        let valid = { (copy: Int) in AdPayload.TrackingEvent(event: "impression", url: "https://ads.test/events/ad-1/impression?copy=\(copy)", offset: nil, part: nil) }
        let tracker = Tracker(adId: "ad-1", entries: [invalid, valid(1), invalid, valid(2), invalid])
        tracker.fire("impression")
        let copies = await fired(2).compactMap { $0.query["copy"] }.sorted()
        #expect(copies == ["1", "2"], "invalid entries before and between valid ones stop nothing")
    }

    @Test func aFailedBeaconIsNotRetried() async throws {
        server.on("/events/", .failure(.notConnectedToInternet))
        let tracker = try makeTracker()
        tracker.fire("impression")
        await sleepMs(150)
        #expect(server.requests(to: "/events/").count == 1)
        tracker.fire("impression")
        await sleepMs(50)
        #expect(server.requests(to: "/events/").count == 1, "fired once, whatever happened to it")
    }
}
}
