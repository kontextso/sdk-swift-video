import Foundation
@testable import KontextVideoSDK
import Testing

/// The debug events of a request and of an ad's life: their names, levels and properties, as both SDKs send them.
extension SerialSuites {
@Suite
@MainActor
struct DebugEventsTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()

    init() {
        pages.install()
    }

    private func makeAds(content: String = "ep-1") async -> VideoAds {
        _ = await harness.initialize()
        return harness.player.ads(for: .init(id: content, language: "en"))
    }

    private func error<T>(_ work: () async throws -> T) async -> VideoAdError? {
        do {
            _ = try await work()
            Issue.record("expected a throw")
            return nil
        } catch let error as VideoAdError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    /// The debug events recorded so far named `name` (the history keeps them whether or not `/config` asked).
    private func events(_ name: String) -> [DebugReporter.Event] {
        EventHistory.recent().filter { $0.name == name }
    }

    @Test func theRequestAndItsFailuresAreDebugEvents() async throws {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-dbg", language: "en"), section: "feed")
        harness.serve(Fixtures.ad(id: "img-dbg1"))
        _ = try await ads.format(.pause)
        let request = try #require(events("ads.request").last)
        #expect(request.properties?["section"] == .string("feed"))
        #expect(request.properties?["held"] == nil, "no held count: nothing held goes on the wire")
        #expect(request.properties?["playhead"] != nil)

        harness.server.on("/v2/video/ads", .json(Fixtures.errors("internal"), status: 503))
        _ = await error { try await ads.format(.linear) }
        let server = try #require(events("ads.requestFailed").last)
        #expect(server.level == .warning && server.sessionId == ads.sessionId)
        #expect(server.properties == ["failure": .string("server"), "httpStatus": .number(503)])

        harness.server.on("/v2/video/ads", .failure(.notConnectedToInternet))
        _ = await error { try await ads.format(.linear) }
        #expect(events("ads.requestFailed").last?.properties == ["failure": .string("offline")])

        _ = AssertionLog()
        KontextVideo.shared.user = nil
        _ = await error { try await ads.format(.linear) }
        #expect(events("ads.requestFailed").last?.properties == ["failure": .string("missingUser")])
    }

    @Test func aFailedConfigIsADebugEvent() async throws {
        harness.server.on("/v2/config", .json(Fixtures.errors("internal"), status: 500))
        #expect(await harness.initialize() == .failed)
        let failed = try #require(events("config.failed").last)
        #expect(failed.level == .warning)
        #expect(failed.properties == ["failure": .string("server"), "httpStatus": .number(500)])
    }

    @Test func notUsedExpiredClickedAndErrorAreDebugEvents() async throws {
        let ads = await makeAds()
        harness.serve(formats: ["pause": Fixtures.ad(id: "img-dbg2"), "overlay": Fixtures.overlayAd(id: "img-dbg3", duration: 6000)])
        let pause = try await ads.format(.pause)
        pause.reject(.outbid(winningPrice: 2))
        let notUsed = try #require(events("ad.notUsed").last)
        #expect(notUsed.bidId == "img-dbg2" && notUsed.level == nil && notUsed.properties == ["reason": .string("outbid")])

        let overlay = try await ads.format(.overlay)
        advanceClock(by: 3601)
        overlay.reject()
        #expect(events("ad.expired").map(\.bidId) == ["img-dbg3"], "an expired ad says so once")
        #expect(events("ad.expired").first?.properties == ["format": .string("overlay")])
        let names = EventHistory.recent().map(\.name)
        #expect(names.lastIndex(of: "ad.expired").map { names[$0 + 1] } == "ad.invalidated", "just before ad.invalidated")
        #expect(events("ad.notUsed").count == 1, "no notice for an expired ad")

        harness.serve(Fixtures.ad(id: "img-dbg4"))
        let clicked = try await ads.format(.pause)
        try await clicked.load()
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        clicked.click(URL(string: "https://advertiser.test")!, fallback: nil, area: .other("cta"))
        #expect(opened.count == 1)
        let click = try #require(events("ad.clicked").last)
        #expect(click.bidId == "img-dbg4" && click.properties == ["area": .string("cta")])

        harness.serve(Fixtures.ad(id: "err-dbg"))
        let failing = try await ads.format(.pause)
        _ = await error { try await failing.load() }
        let adError = try #require(events("ad.error").last)
        #expect(adError.bidId == "err-dbg" && adError.level == .error && adError.properties == ["code": .number(502)])

        harness.serve(Fixtures.overlayAd(id: "img-dbg5"))
        _ = try await ads.format(.overlay)
        ads.destroy()
        #expect(events("ad.notUsed").last?.properties == ["reason": .string("destroyed")], "destroy's notice too")
    }
}
}
