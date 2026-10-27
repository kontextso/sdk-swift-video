import Foundation
@testable import KontextVideoSDK
import Testing

/// `/debug` reporting: off until `/config` asks, batched once per interval, the body's shape, and never
/// anything the spec forbids.
extension SerialSuites {
@Suite
@MainActor
struct DebugReporterTests {
    private let harness = SDKHarness()

    init() {
        DebugReporter.interval = 0.05
    }

    @Test func nothingIsSentWhileDisabled() async {
        _ = await harness.initialize()
        DebugReporter.shared.event("ads.request", state: ["format": "pause"])
        await sleepMs(150)
        #expect(harness.server.requests(to: "/v2/debug").isEmpty)
    }

    @Test func enabledByInitEventsAreBatchedWithTheBodyShape() async throws {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        DebugReporter.shared.event("ads.request", state: ["format": "pause", "playhead": 1200, "filled": true])
        DebugReporter.shared.event("ad.loaded", adId: "ad-1", level: .warning, state: ["durationMs": 842])
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/debug").count >= 1 })
        let body = try #require(harness.server.requests(to: "/v2/debug").last?.body)
        #expect(body["publisherToken"] as? String == "test-dev")
        #expect(body["installId"] as? String == KontextVideo.installId)
        #expect((body["sdk"] as? [String: Any])?["name"] as? String == "sdk-swift-video")
        let events = try #require(body["events"] as? [[String: Any]])
        let names = events.map { $0["name"] as? String }
        #expect(names.contains("config.response"))
        #expect(names.contains("ads.request") && names.contains("ad.loaded"))
        let request = try #require(events.first { $0["name"] as? String == "ads.request" })
        let createdAt = try #require(request["createdAt"] as? String)
        #expect(createdAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil, "ISO 8601 with milliseconds, UTC: \(createdAt)")
        #expect(request["adId"] == nil)
        let state = request["state"] as? [String: Any]
        #expect(state?["format"] as? String == "pause")
        #expect(state?["playhead"] as? Double == 1200)
        #expect(state?["filled"] as? Bool == true)
        let loaded = try #require(events.first { $0["name"] as? String == "ad.loaded" })
        #expect(loaded["adId"] as? String == "ad-1")
        #expect(loaded["level"] as? String == "warning")
    }

    @Test func eventsAreCoalescedIntoOneRequestPerInterval() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        await sleepMs(120)
        let before = harness.server.requests(to: "/v2/debug").count
        for i in 0..<20 {
            DebugReporter.shared.event("tick", state: ["i": .number(Double(i))])
        }
        await sleepMs(200)
        let batches = harness.server.requests(to: "/v2/debug").dropFirst(before)
        #expect(batches.count == 1, "twenty events, one request")
        #expect((batches.first?.body?["events"] as? [[String: Any]])?.count == 20)
    }

    @Test func disablingDropsTheBuffer() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        await sleepMs(120)
        let before = harness.server.requests(to: "/v2/debug").count
        DebugReporter.shared.event("tick")
        DebugReporter.shared.isEnabled = false
        await sleepMs(150)
        #expect(harness.server.requests(to: "/v2/debug").count == before)
    }

    @Test func aFailedBatchIsLostQuietly() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        harness.server.on("/v2/debug", .failure(.notConnectedToInternet))
        _ = await harness.initialize()
        DebugReporter.shared.event("tick")
        await sleepMs(200)
        #expect(harness.server.requests(to: "/v2/debug").count >= 1)
        DebugReporter.shared.event("tick")
        await sleepMs(150)
        #expect(DebugReporter.shared.isEnabled, "reporting stays on; a lost batch is lost")
    }

    @Test func oneRequestAtATimeAndTheRestWaitForIt() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        await sleepMs(120)   // the config.response batch is out
        let before = harness.server.requests(to: "/v2/debug").count
        var slow = StubServer.Response.empty()
        slow.delay = 0.3
        harness.server.on("/v2/debug", slow)
        DebugReporter.shared.event("first")
        await sleepMs(100)   // the first batch is in flight now, for 300 ms
        for i in 0..<5 {
            DebugReporter.shared.event("later", state: ["i": .number(Double(i))])
            await sleepMs(20)
        }
        #expect(harness.server.requests(to: "/v2/debug").count == before + 1, "no second request while the first is answered")
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/debug").count == before + 2 })
        let second = harness.server.requests(to: "/v2/debug").last?.body?["events"] as? [[String: Any]]
        #expect(second?.count == 5, "the events that arrived meanwhile left together, after")
        await sleepMs(200)
        #expect(harness.server.requests(to: "/v2/debug").count == before + 2, "and nothing more")
    }

    @Test func theBufferKeepsTheNewestEventsOnly() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        harness.server.on("/v2/debug", .failure(.notConnectedToInternet))
        _ = await harness.initialize()
        DebugReporter.shared.event("fill")   // opens a batch that will fail; the rest pile up behind it
        await sleepMs(20)
        for i in 0..<(DebugReporter.maxBuffered + 10) {
            DebugReporter.shared.event("tick", state: ["i": .number(Double(i))])
        }
        harness.server.on("/v2/debug", .empty())
        #expect(await waitUntil(3) { self.harness.server.requests(to: "/v2/debug").contains { ($0.body?["events"] as? [[String: Any]])?.count == DebugReporter.maxBuffered } })
        let batch = harness.server.requests(to: "/v2/debug").last?.body?["events"] as? [[String: Any]]
        #expect((batch?.first?["state"] as? [String: Any])?["i"] as? Double == 10, "the oldest ten were dropped")
    }

    @Test func aNumberBeyondIntFormatsWithoutATrap() {
        #expect(DebugReporter.line("n", adId: nil, state: ["a": .number(1e30)]) == "n a=1e+30")
        #expect(DebugReporter.line("n", adId: nil, state: ["a": .number(.infinity)]) == "n a=inf")
        #expect(DebugReporter.line("n", adId: nil, state: ["a": .number(.nan)]) == "n a=nan")
        #expect(DebugReporter.line("n", adId: nil, state: ["a": .number(42), "b": .number(1.5)]) == "n a=42 b=1.5")
        DebugReporter.shared.event("n", state: ["a": .number(.infinity)])   // the console line is formatted whether or not reporting is on
    }

    @Test func theLoadFlowReportsItsEvents() async throws {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        let pages = FramePageServer()
        pages.install()
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        harness.serve(Fixtures.ad(id: "img-dbg"))
        _ = try await ads.format(.pause).load()
        #expect(await waitUntil { self.allNames().contains("ad.loaded") })
        let names = allNames()
        #expect(names.contains("ads.request"))
        #expect(names.contains("ads.response"))
        #expect(names.contains("ad.loaded"))
        for body in harness.server.requests(to: "/v2/debug").compactMap(\.body) {
            let text = try #require(String(bytes: JSONSerialization.data(withJSONObject: body), encoding: .utf8))
            #expect(!text.contains("idfv") && !text.contains("email") && !text.contains("gdprConsent"), "never the forbidden fields")
        }
    }

    @Test func anEventReadsAsOneConsoleLine() {
        #expect(DebugReporter.line("ad.loaded", adId: "f1a2b3c4-5d6e", state: ["durationMs": 842, "format": "pause", "filled": true]) == "ad.loaded ad=f1a2b3c4 durationMs=842 filled=true format=pause")
        #expect(DebugReporter.line("config.response", adId: nil, state: nil) == "config.response")
    }

    private func allNames() -> [String] {
        harness.server.requests(to: "/v2/debug").flatMap { ($0.body?["events"] as? [[String: Any]]) ?? [] }.compactMap { $0["name"] as? String }
    }
}
}
