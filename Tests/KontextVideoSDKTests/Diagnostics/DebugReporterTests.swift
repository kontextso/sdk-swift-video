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
    private let SESSION_ID = "0192f1a2-7b3c-7d4e-8f50-6172839aabbc"
    private let BID_ID = "0192f1a2-7b3c-7d4e-8f50-6172839aabbd"

    @Test func nothingIsSentWhileDisabled() async {
        _ = await harness.initialize()
        DebugReporter.shared.event("ads.request", properties: ["format": "pause"])
        await sleepMs(150)
        #expect(harness.server.requests(to: "/v2/debug").isEmpty)
    }

    @Test func enabledByInitEventsAreBatchedWithTheBodyShape() async throws {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        DebugReporter.shared.event("ads.request", properties: ["format": "pause", "playhead": 1200, "filled": true])
        DebugReporter.shared.event("ad.loaded", sessionId: SESSION_ID, bidId: BID_ID, level: .warning, properties: ["durationMs": 842])
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/debug").count >= 1 })
        let body = try #require(harness.server.requests(to: "/v2/debug").last?.body)
        #expect(body["publisherToken"] as? String == "test-dev")
        #expect(body["installId"] as? String == KontextVideo.installId)
        #expect((body["sdk"] as? [String: Any])?["name"] as? String == "sdk-swift-video")
        #expect((body["app"] as? [String: Any])?["version"] is String && (body["os"] as? [String: Any])?["version"] is String, "the envelope an error batch has: app and OS, each with its version")
        let events = try #require(body["events"] as? [[String: Any]])
        let names = events.map { $0["name"] as? String }
        #expect(names.contains("config.response"))
        #expect(names.contains("ads.request") && names.contains("ad.loaded"))
        let request = try #require(events.first { $0["name"] as? String == "ads.request" })
        let occurredAt = try #require(request["occurredAt"] as? String)
        #expect(occurredAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil, "ISO 8601 with milliseconds, UTC: \(occurredAt)")
        #expect(request["bidId"] == nil && request["sessionId"] == nil)
        let properties = request["properties"] as? [String: Any]
        #expect(properties?["format"] as? String == "pause")
        #expect(properties?["playhead"] as? Double == 1200)
        #expect(properties?["filled"] as? Bool == true)
        let loaded = try #require(events.first { $0["name"] as? String == "ad.loaded" })
        #expect(loaded["bidId"] as? String == BID_ID && loaded["sessionId"] as? String == SESSION_ID)
        #expect(loaded["level"] as? String == "warning")
    }

    @Test func eventsAreCoalescedIntoOneRequestPerInterval() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        for i in 0..<20 {
            DebugReporter.shared.event("tick", properties: ["i": .number(Double(i))])
        }
        // The SDK's own startup events may go out in a batch of their own, at any moment on a slow runner;
        // what matters is that the twenty ticks travel together.
        #expect(await waitUntil { !batchesWithTicks().isEmpty })
        await sleepMs(200)
        let batches = batchesWithTicks()
        #expect(batches.count == 1, "twenty events, one request")
        #expect(batches.first?.filter { $0["name"] as? String == "tick" }.count == 20)
    }

    @Test func disablingDropsTheBuffer() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        DebugReporter.shared.event("tick")
        KontextVideo.shared.recordDebugReporting(false)
        await sleepMs(300)
        #expect(batchesWithTicks().isEmpty, "the tick was buffered, then dropped")
    }

    /// The events of every debug batch that carried a `tick`, the event these tests send.
    private func batchesWithTicks() -> [[[String: Any]]] {
        harness.server.requests(to: "/v2/debug")
            .compactMap { $0.body?["events"] as? [[String: Any]] }
            .filter { events in events.contains { $0["name"] as? String == "tick" } }
    }

    @Test func aFailedBatchIsLostQuietlyAndTheNextOneGoesOut() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        harness.server.on("/v2/debug", .failure(.notConnectedToInternet))
        DebugReporter.shared.event("lost-once")
        #expect(await waitUntil { !self.batches(named: "lost-once").isEmpty })
        harness.server.on("/v2/debug", .empty())
        DebugReporter.shared.event("after-the-loss")
        #expect(await waitUntil { !self.batches(named: "after-the-loss").isEmpty })
        await sleepMs(150)
        #expect(batches(named: "lost-once").count == 1, "a failed batch is never sent again")
        #expect(batches(named: "after-the-loss").count == 1, "the next event goes out once")
        #expect(DebugReporter.shared.isEnabled, "reporting stays on")
    }

    @Test func debugReportsCarryNoneOfTheViewersData() async throws {
        // Canaries in every private field, then a request and its answer, which report the most.
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        KontextVideo.shared.user = KontextVideo.User(id: "canary-user-id", email: "canary@viewer.test", emailHash: "canary-hash", keywords: ["canary-keyword"])
        KontextVideo.shared.regulatory = KontextVideo.Regulatory(gdprConsent: "canary-tc-string", gpp: "canary-gpp", usPrivacy: "canary-usp")
        let ads = harness.player.ads(for: .init(id: "ep", language: "en", title: "canary-title"))
        harness.serve(Fixtures.ad(id: "img-priv"))
        _ = try await ads.format(.pause)
        #expect(await waitUntil { self.allNames().contains("ads.response") })
        for body in harness.server.requests(to: "/v2/debug").compactMap(\.body) {
            let text = try #require(String(bytes: JSONSerialization.data(withJSONObject: body), encoding: .utf8))
            for canary in ["canary-user-id", "canary@viewer.test", "canary-hash", "canary-keyword", "canary-tc-string", "canary-gpp", "canary-usp", "canary-title"] {
                #expect(!text.contains(canary), "\(canary) reached a debug report")
            }
            #expect(!text.contains("idfv") && !text.contains("email") && !text.contains("gdprConsent"), "never the forbidden fields")
        }
        ads.destroy()
    }

    @Test func oneRequestAtATimeAndTheRestWaitForIt() async {
        // Batches are told apart by the test's own event names, not by counting requests: the startup
        // batch can land at any time on a slow runner.
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        var slow = StubServer.Response.empty()
        slow.delay = 3   // the first batch stays in flight while the test sends the rest
        harness.server.on("/v2/debug", slow)
        DebugReporter.shared.event("first")
        #expect(await waitUntil { !self.batches(named: "first").isEmpty })
        // Only that batch is slow: the later one answers at once, so nothing is left in flight for the
        // next test (the reporter is shared). A request takes its answer when it arrives.
        harness.server.on("/v2/debug", .empty())
        for i in 0..<5 {
            DebugReporter.shared.event("later", properties: ["i": .number(Double(i))])
        }
        #expect(batches(named: "later").isEmpty, "no second request while the first is answered")
        #expect(await waitUntil(10) { !self.batches(named: "later").isEmpty })
        let later = batches(named: "later")
        #expect(later.count == 1 && later.first?.count == 5, "the five left together, in one batch")
        // Started only after the first was answered (3 s): a lower bound, which a slow runner cannot break.
        let started = { (name: String) in self.harness.server.requests(to: "/v2/debug").first { ($0.body?["events"] as? [[String: Any]])?.contains { $0["name"] as? String == name } == true }?.receivedAt }
        if let first = started("first"), let second = started("later") {
            #expect(second.timeIntervalSince(first) >= 2.9, "the second request waited for the first answer: \(second.timeIntervalSince(first)) s")
        }
    }

    /// The batches that carry an event called `name`, each as its list of events.
    private func batches(named name: String) -> [[[String: Any]]] {
        harness.server.requests(to: "/v2/debug")
            .compactMap { $0.body?["events"] as? [[String: Any]] }
            .filter { events in events.contains { $0["name"] as? String == name } }
    }

    @Test func theBufferKeepsTheNewestEventsOnly() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        harness.server.on("/v2/debug", .failure(.notConnectedToInternet))
        _ = await harness.initialize()
        DebugReporter.shared.event("fill")   // opens a batch that will fail; the rest pile up behind it
        await sleepMs(20)
        for i in 0..<(DebugReporter.maxBuffered + 10) {
            DebugReporter.shared.event("tick", properties: ["i": .number(Double(i))])
        }
        harness.server.on("/v2/debug", .empty())
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/debug").contains { ($0.body?["events"] as? [[String: Any]])?.count == DebugReporter.maxBuffered } })
        let batch = harness.server.requests(to: "/v2/debug").last?.body?["events"] as? [[String: Any]]
        #expect((batch?.first?["properties"] as? [String: Any])?["i"] as? Double == 10, "the oldest ten were dropped")
    }

    @Test func aNumberBeyondIntFormatsWithoutATrap() {
        #expect(DebugReporter.line("n", bidId: nil, properties: ["a": .number(1e30)]) == "n a=1e+30")
        #expect(DebugReporter.line("n", bidId: nil, properties: ["a": .number(.infinity)]) == "n a=inf")
        #expect(DebugReporter.line("n", bidId: nil, properties: ["a": .number(.nan)]) == "n a=nan")
        #expect(DebugReporter.line("n", bidId: nil, properties: ["a": .number(42), "b": .number(1.5)]) == "n a=42 b=1.5")
        DebugReporter.shared.event("n", properties: ["a": .number(.infinity)])   // the console line is formatted whether or not reporting is on
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
        #expect(DebugReporter.line("ad.loaded", bidId: "f1a2b3c4-5d6e", properties: ["durationMs": 842, "format": "pause", "filled": true]) == "ad.loaded ad=f1a2b3c4 durationMs=842 filled=true format=pause")
        #expect(DebugReporter.line("config.response", bidId: nil, properties: nil) == "config.response")
    }

    @Test func consoleLinesAreForwardedAsLogEventsWhileDebugIsOnOnly() async throws {
        _ = await harness.initialize()   // reportDebug left out: off
        Logger.warning("canary-off https://ads.test/f?ifa=secret")
        await sleepMs(150)
        #expect(harness.server.requests(to: "/v2/debug").isEmpty, "nothing leaves while off")
        KontextVideo.shared.resetForTesting()
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        Logger.level = .none   // the console shows nothing; the server still gets every line
        Logger.warning("canary-on https://ads.test/f?ifa=secret&x=1 answered 410")
        Logger.debug("canary-debug")
        #expect(await waitUntil { self.logEvents().contains { $0["message"] as? String == "canary-debug" } })
        let line = try #require(logEvents().first { ($0["message"] as? String)?.hasPrefix("canary-on") == true })
        #expect(line["message"] as? String == "canary-on https://ads.test/f answered 410", "the URL without its query")
        #expect(line["level"] as? String == "warning")
        #expect(!allNames().contains("canary-on"), "a line is an event called log")
        let text = try #require(String(bytes: try JSONSerialization.data(withJSONObject: harness.server.requests(to: "/v2/debug").map { $0.body ?? [:] }), encoding: .utf8))
        #expect(!text.contains("secret"), "the query never leaves")
    }

    @Test func aLineLoggedOffTheMainThreadIsForwardedToo() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        DispatchQueue.global().async { Logger.warning("canary-background HTTPS://Ads.Test/F?ifa=secret kontext-test://frames/x?q=1 brandapp:offer?ifa=secret done") }
        #expect(await waitUntil { self.logEvents().contains { ($0["message"] as? String)?.hasPrefix("canary-background") == true } })
        let line = logEvents().first { ($0["message"] as? String)?.hasPrefix("canary-background") == true }
        #expect(line?["message"] as? String == "canary-background HTTPS://Ads.Test/F kontext-test://frames/x brandapp:offer done", "every scheme, any case, with or without //")
    }

    @Test func anIntervalOfZeroSendsEachEventAsItHappens() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true, debugBatchInterval: 0)))
        _ = await harness.initialize()
        #expect(DebugReporter.shared.interval == 0)
        DebugReporter.shared.event("alone-a")
        #expect(await waitUntil { !self.batches(named: "alone-a").isEmpty })
        DebugReporter.shared.event("alone-b")
        #expect(await waitUntil { !self.batches(named: "alone-b").isEmpty })
        #expect(batches(named: "alone-a").first?.contains { $0["name"] as? String == "alone-b" } == false, "each left on its own")
    }

    /// Every `log` event the server got, as its level and properties flattened: `message` and `level`.
    private func logEvents() -> [[String: Any]] {
        harness.server.requests(to: "/v2/debug").flatMap { ($0.body?["events"] as? [[String: Any]]) ?? [] }
            .filter { $0["name"] as? String == "log" }
            .map { event in (event["properties"] as? [String: Any] ?? [:]).merging(["level": event["level"] ?? ""]) { $1 } }
    }

    private func allNames() -> [String] {
        harness.server.requests(to: "/v2/debug").flatMap { ($0.body?["events"] as? [[String: Any]]) ?? [] }.compactMap { $0["name"] as? String }
    }
}
}
