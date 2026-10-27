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

    private func fired() async -> [(adId: String, event: String, query: [String: String])] {
        await sleepMs(100)
        return server.beacons
    }

    @Test func firesEachEntryOnce() async throws {
        let tracker = try makeTracker()
        tracker.fire("impression")
        tracker.fire("impression")
        tracker.fire("impression")
        let beacons = await fired()
        #expect(beacons.map(\.event) == ["impression"])
    }

    @Test func clicksAndPlaybackTogglesFireEveryTimeWithTheirOwnFireId() async throws {
        let tracker = try makeTracker()
        let first = tracker.fire("click")
        let second = tracker.fire("click")
        tracker.fire("pause")
        tracker.fire("resume")
        tracker.fire("pause")
        tracker.fire("start")
        tracker.fire("start")
        let beacons = await fired()
        #expect(beacons.map(\.event) == ["click", "click", "pause", "resume", "pause", "start"], "clicks and toggles repeat; start is once")
        let clickIds = beacons.filter { $0.event == "click" }.map { $0.query["fid"] }
        #expect(clickIds == [first, second] && first != second, "a second click is a second fire")
        let through = tracker.clickThrough(URL(string: "https://ads.test/redirect?fid=%5BKONTEXT_FIREID%5D&q=%5Bkept%5D")!, fireId: second)
        #expect(through.query == "fid=\(second)&q=%5Bkept%5D", "the click-through carries its click's fire id; a bracket that is no macro survives")
    }

    @Test func everyFireCarriesItsOwnFireIdSharedByItsURLs() async throws {
        let tracker = try makeTracker()
        tracker.fire("impression")
        tracker.fire("click")
        let beacons = await fired()
        let fids = beacons.map { $0.query["fid"] ?? "" }
        #expect(fids.allSatisfy { UUID(uuidString: $0) != nil }, "a UUID per fire: \(fids)")
        #expect(Set(fids).count == beacons.count, "a different fire id per event occurrence")
    }

    @Test func firesTheGetWithTheSDKsTimeoutAndNoCache() async throws {
        let tracker = try makeTracker()
        tracker.fire("loaded")
        _ = await fired()
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
        let beacons = await fired()
        #expect(beacons.map(\.event) == ["creativeView", "creativeView", "click"])
        #expect(beacons[0].query["part"] == nil)
        #expect(beacons[1].query["part"] == "endCard")
        #expect(beacons[2].query["part"] == "endCard")
    }

    @Test func selectsProgressByOffset() async throws {
        let tracker = try makeTracker()
        tracker.fire("progress", offset: 4000)
        tracker.fire("progress", offset: 5000)
        tracker.fire("progress", offset: 5000)
        let beacons = await fired()
        #expect(beacons.map(\.event) == ["progress"])
        #expect(beacons[0].query["offset"] == "5000")
    }

    @Test func unknownEventsFireNothing() async throws {
        let tracker = try makeTracker(video: false)
        tracker.fire("rewind")
        tracker.fire("start", part: nil)
        #expect(await fired().isEmpty, "an image creative has no start entry; rewind is not in the list")
    }

    @Test func substitutesEveryMacro() async throws {
        let tracker = try makeTracker()
        tracker.contentPlayhead = { 3661.25 }
        tracker.adPlayhead = 7_500
        tracker.fire("error", errorCode: 405)
        let beacon = try #require(await fired().first)
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
        #expect(abs(parsed.timeIntervalSinceNow) < 5, "the moment of firing")
    }

    @Test func playheadsAreWholeMillisecondsNeverOneShort() async throws {
        let tracker = try makeTracker()
        tracker.contentPlayhead = { 9.806 }   // 9.80599… in binary: truncating the fraction gives .805
        tracker.adPlayhead = 59_999
        tracker.fire("error", errorCode: 400)
        let beacon = try #require(await fired().first)
        #expect(beacon.query["cph"] == "00:00:09.806")
        #expect(beacon.query["aph"] == "00:00:59.999")
    }

    @Test func theDeprecatedContentPlayheadIsFilledLikeMediaPlayhead() async throws {
        let tracker = Tracker(adId: "ad-1", entries: [
            AdPayload.TrackingEvent(event: "impression", url: "https://ads.test/events/ad-1/impression?old=[CONTENTPLAYHEAD]&new=[MEDIAPLAYHEAD]&x=[KONTEXT_UNKNOWN]", offset: nil, part: nil),
        ])
        tracker.contentPlayhead = { 2 }
        tracker.fire("impression")
        let beacon = try #require(await fired().first)
        #expect(beacon.query["old"] == "00:00:02.000" && beacon.query["new"] == "00:00:02.000")
        #expect(beacon.query["x"] == "[KONTEXT_UNKNOWN]", "a macro the SDK does not know stays in place")
        let raw = try #require(server.requests(to: "/events/").first?.request.url?.absoluteString)
        #expect(raw.contains("x=%5BKONTEXT_UNKNOWN%5D") && !raw.contains("%25"), "its brackets are encoded, so nothing else is re-encoded: \(raw)")
    }

    @Test func cacheBustingDiffersPerBeacon() async throws {
        let tracker = try makeTracker()
        tracker.fire("start")
        tracker.fire("firstQuartile")
        let beacons = await fired()
        #expect(beacons.count == 2)
        #expect(beacons[0].query["cb"] != beacons[1].query["cb"])
    }

    @Test func macrosAreURLEncoded() async throws {
        let tracker = try makeTracker()
        tracker.fire("loaded")
        _ = await fired()
        let raw = try #require(server.requests(to: "/events/").first?.request.url?.absoluteString)
        #expect(raw.range(of: "cph=00%3A00%3A00.000") != nil, "colons in playheads are escaped")
        let ts = try #require(URLComponents(string: raw)?.percentEncodedQueryItems?.first { $0.name == "ts" }?.value)
        #expect(ts.contains("%3A") && !ts.contains(":"), "the timestamp's colons are escaped: \(ts)")
    }

    @Test func invalidURLsAreSkippedWithoutStoppingOthers() async throws {
        let tracker = Tracker(adId: "ad-1", entries: [
            AdPayload.TrackingEvent(event: "impression", url: "https://ads.test/events/ad-1/impression?x=[CACHEBUSTING]", offset: nil, part: nil),
            AdPayload.TrackingEvent(event: "impression", url: "", offset: nil, part: nil),   // the one string URL(string:) still refuses
        ])
        tracker.fire("impression")
        #expect(await fired().map(\.event) == ["impression"])
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
