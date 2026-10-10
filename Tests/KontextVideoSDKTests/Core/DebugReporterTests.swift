import Foundation
@testable import KontextVideoSDK
import Testing

/// `/debug` reporting: off until `/init` asks, batched once per interval, the body's shape, and never
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
        DebugReporter.shared.event("ads.request", state: ["placementId": "x"])
        await sleepMs(150)
        #expect(harness.server.requests(to: "/v2/debug").isEmpty)
    }

    @Test func enabledByInitEventsAreBatchedWithTheBodyShape() async throws {
        harness.server.on("/v2/init", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        DebugReporter.shared.event("ads.request", state: ["placementId": "pause", "playhead": 1200, "filled": true])
        DebugReporter.shared.event("ad.loaded", adId: "ad-1", level: "warning", state: ["durationMs": 842])
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/debug").count >= 1 })
        let body = try #require(harness.server.requests(to: "/v2/debug").last?.body)
        #expect(body["publisherToken"] as? String == "test-dev")
        #expect(body["installId"] as? String == KontextVideo.installId)
        #expect((body["sdk"] as? [String: Any])?["name"] as? String == "sdk-swift-video")
        let events = try #require(body["events"] as? [[String: Any]])
        let names = events.map { $0["name"] as? String }
        #expect(names.contains("init.response"))
        #expect(names.contains("ads.request") && names.contains("ad.loaded"))
        let request = try #require(events.first { $0["name"] as? String == "ads.request" })
        #expect(request["at"] is Int)
        #expect(request["adId"] == nil)
        let state = request["state"] as? [String: Any]
        #expect(state?["placementId"] as? String == "pause")
        #expect(state?["playhead"] as? Double == 1200)
        #expect(state?["filled"] as? Bool == true)
        let loaded = try #require(events.first { $0["name"] as? String == "ad.loaded" })
        #expect(loaded["adId"] as? String == "ad-1")
        #expect(loaded["level"] as? String == "warning")
    }

    @Test func eventsAreCoalescedIntoOneRequestPerInterval() async {
        harness.server.on("/v2/init", .json(Fixtures.initEnabled(reportDebug: true)))
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
        harness.server.on("/v2/init", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        await sleepMs(120)
        let before = harness.server.requests(to: "/v2/debug").count
        DebugReporter.shared.event("tick")
        DebugReporter.shared.isEnabled = false
        await sleepMs(150)
        #expect(harness.server.requests(to: "/v2/debug").count == before)
    }

    @Test func aFailedBatchIsLostQuietly() async {
        harness.server.on("/v2/init", .json(Fixtures.initEnabled(reportDebug: true)))
        harness.server.on("/v2/debug", .failure(.notConnectedToInternet))
        _ = await harness.initialize()
        DebugReporter.shared.event("tick")
        await sleepMs(200)
        #expect(harness.server.requests(to: "/v2/debug").count >= 1)
        DebugReporter.shared.event("tick")
        await sleepMs(150)
        #expect(DebugReporter.shared.isEnabled, "reporting stays on; a lost batch is lost")
    }

    @Test func theLoadFlowReportsItsEvents() async throws {
        harness.server.on("/v2/init", .json(Fixtures.initEnabled(reportDebug: true)))
        let pages = FramePageServer()
        pages.install()
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep", language: "en"), player: harness.player)
        harness.serve(Fixtures.ad(id: "img-dbg"))
        _ = try await ads.pausePlacement("pause").load()
        #expect(await waitUntil { self.allNames().contains("ad.loaded") })
        let names = allNames()
        #expect(names.contains("ads.request"))
        #expect(names.contains("ads.response"))
        #expect(names.contains("ad.loaded"))
        for body in harness.server.requests(to: "/v2/debug").compactMap(\.body) {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            #expect(!text.contains("idfv") && !text.contains("email") && !text.contains("gdprConsent"), "never the forbidden fields")
        }
    }

    private func allNames() -> [String] {
        harness.server.requests(to: "/v2/debug").flatMap { ($0.body?["events"] as? [[String: Any]]) ?? [] }.compactMap { $0["name"] as? String }
    }
}
}
