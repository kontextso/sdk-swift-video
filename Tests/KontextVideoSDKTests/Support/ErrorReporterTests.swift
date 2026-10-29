import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// Error reports: off until `/config` turns them on, every fault coded once at its source, the body carrying
/// ids and never personal data, and bounded delivery (retry unchanged, `410` stops, other `4xx` drops).
extension SerialSuites {
@Suite
@MainActor
struct ErrorReporterTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameBridge.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    private var reporter: ErrorReporter { ErrorReporter.shared }

    init() {
        window.add(harness.player.view)
    }

    /// Every report that reached the server, in order.
    private func reports() -> [[String: Any]] {
        harness.server.requests(to: "/v2/error").flatMap { ($0.body?["errors"] as? [[String: Any]]) ?? [] }
    }

    private func reports(_ code: String) -> [[String: Any]] {
        reports().filter { $0["code"] as? String == code }
    }

    private func enableReports() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportErrors: true)))
        _ = await harness.initialize()
    }

    /// A loaded ad owned by `ads`, its page driven by hand.
    private func loadedAd(_ payload: [String: Any], in ads: VideoAds) throws -> VideoAd {
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        ad.bridge.receive(["adId": ad.id, "type": "ad.loaded"], from: sender)
        return ad
    }

    // MARK: The switch

    @Test func reportsAreOffWhenConfigLeavesThemOutOrDisablesTheSDK() async {
        _ = await harness.initialize()
        #expect(reporter.mode == .off, "reportErrors left out is off")
        reporter.report(.skanFailed, stage: .attribution, detail: "start")
        #expect(reporter.buffer.isEmpty)
        sdkReset()
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        _ = await harness.initialize()
        #expect(reporter.mode == .off, "a disabled SDK reports nothing")
        await sleepMs(50)
        #expect(harness.server.requests(to: "/v2/error").isEmpty)
    }

    @Test func aFailedConfigWaitsAndLeavesOnceALaterConfigTurnsReportsOn() async throws {
        harness.server.on("/v2/config", .failure(.timedOut))
        _ = await harness.initialize()
        #expect(reporter.mode == .pending && reporter.buffer.map(\.code) == ["config.failed"], "kept in memory")
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportErrors: true)))
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        harness.serve(Fixtures.ad(id: "img-er1"))
        _ = try await ads.format(.pause)   // retries /config, which turns the reports on
        #expect(await waitUntil { !self.reports("config.failed").isEmpty })
        let report = try #require(reports("config.failed").first)
        #expect(report["stage"] as? String == "config" && report["detail"] as? String == "network")
        #expect((report["underlying"] as? [String: Any])?["domain"] as? String == NSURLErrorDomain)
        #expect((report["underlying"] as? [String: Any])?["code"] as? Int == URLError.timedOut.rawValue)
        #expect((report["requestId"] as? String)?.isEmpty == false)
    }

    // MARK: Request failures

    @Test func aFailedRequestSharedByThreeCallsIsOneReport() async throws {
        await enableReports()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        let gate = StubServer.Gate()
        defer { gate.open() }
        var failing = StubServer.Response.json(Fixtures.errors("internal", status: 500), status: 500)
        failing.gate = gate
        harness.server.on("/v2/video/ads", failing)
        let calls = AdFormat.allCases.map { format in Task { try? await ads.format(format) } }
        #expect(await waitUntil { self.harness.adsRequests.count == 1 })
        gate.open()
        for call in calls { _ = await call.value }
        #expect(await waitUntil { !self.reports("ads.request_failed").isEmpty })
        await sleepMs(50)
        let failures = reports("ads.request_failed")
        #expect(failures.count == 1, "one request, one report, however many callers waited")
        let report = try #require(failures.first)
        #expect(report["httpStatus"] as? Int == 500 && report["stage"] as? String == "request")
        #expect(report["requestId"] as? String == ads.lastRequestId && ads.lastRequestId != nil, "the id the app can quote")
        #expect(report["sessionId"] as? String == ads.sessionId && report["recovery"] as? String == "no_ad")
        let history = (report["history"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(history.contains("ads.request"), "what happened just before: \(history)")
        let moment = try #require((report["history"] as? [[String: Any]])?.first { $0["name"] as? String == "ads.request" })
        let createdAt = try #require(moment["createdAt"] as? String)
        #expect(createdAt.hasSuffix("Z") && createdAt.contains("T") && createdAt.contains("."), "ISO 8601 with milliseconds in UTC: \(createdAt)")
        #expect(moment["at"] == nil, "a date, not seconds before the error")
    }

    @Test func anAnswerThatBreaksTheContractIsADecodeFailure() async {
        await enableReports()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        harness.server.on("/v2/video/ads", .json(["nonsense": true]))
        _ = try? await ads.format(.pause)
        #expect(await waitUntil { !self.reports("ads.decode_failed").isEmpty })
        #expect(reports("ads.request_failed").isEmpty)
    }

    @Test func theBodyCarriesIdsAndNeverPersonalData() async throws {
        await enableReports()
        KontextVideo.shared.user = .init(id: "user-secret-1", email: "secret@example.com")
        KontextVideo.shared.regulatory = .init(gdprConsent: "CONSENT-SECRET")
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        harness.server.on("/v2/video/ads", .json(Fixtures.errors("internal", status: 500), status: 500))
        _ = try? await ads.format(.pause)
        #expect(await waitUntil { !self.harness.server.requests(to: "/v2/error").isEmpty })
        let request = try #require(harness.server.requests(to: "/v2/error").first)
        let raw = String(bytes: request.rawBody, encoding: .utf8) ?? ""
        #expect(!raw.contains("user-secret-1") && !raw.contains("secret@example.com") && !raw.contains("CONSENT-SECRET"), "\(raw)")
        let body = try #require(request.body)
        #expect(body["publisherToken"] as? String == "test-dev" && body["installId"] as? String == KontextVideo.installId)
        #expect((body["sdk"] as? [String: Any])?["name"] as? String == SDKInfo.name)
        #expect((body["app"] as? [String: Any])?["bundleId"] != nil && (body["os"] as? [String: Any])?["name"] != nil)
        #expect((body["batchId"] as? String)?.isEmpty == false && body["dropped"] as? Int == 0)
    }

    // MARK: Delivery

    @Test func aBatchThatFailsIsRetriedUnchanged() async throws {
        await enableReports()
        ErrorReporter.retryDelay = 0.05
        var calls = 0
        harness.server.on("/v2/error") { _ in
            calls += 1
            return calls == 1 ? .failure(.notConnectedToInternet) : .empty()
        }
        reporter.report(.skanFailed, stage: .attribution, adId: "ad-1", detail: "start")
        // Two round trips and a backoff: a loaded CI runner resumes tasks seconds late.
        #expect(await waitUntil(5) { calls == 2 })
        let bodies = harness.server.requests(to: "/v2/error").compactMap(\.body)
        #expect(bodies.count == 2)
        #expect(bodies[0]["batchId"] as? String == bodies[1]["batchId"] as? String, "the same batch, so the server counts it once")
        let ids = bodies.map { (($0["errors"] as? [[String: Any]])?.first?["id"] as? String) ?? "" }
        #expect(ids[0] == ids[1] && !ids[0].isEmpty, "the same report, as it was")
    }

    @Test func a410StopsReportingForTheLaunchAndOther4xxDropTheBatch() async {
        await enableReports()
        harness.server.on("/v2/error", .empty(400))
        reporter.report(.skanFailed, stage: .attribution, detail: "start")
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/error").count == 1 })
        await sleepMs(50)
        #expect(harness.server.requests(to: "/v2/error").count == 1 && reporter.mode == .on, "a refused batch is not retried")
        harness.server.on("/v2/error", .empty(410))
        reporter.report(.skanFailed, stage: .attribution, detail: "end")
        #expect(await waitUntil { self.harness.server.requests(to: "/v2/error").count == 2 })
        #expect(await waitUntil { self.reporter.mode == .off }, "410: off for this launch")
        reporter.report(.skanFailed, stage: .attribution, detail: "dispose")
        await sleepMs(50)
        #expect(harness.server.requests(to: "/v2/error").count == 2 && reporter.buffer.isEmpty)
    }

    @Test func reportsBeyondTheBufferAreDroppedAndCountedOnce() async {
        for index in 0..<(ErrorReporter.maxBuffered + 5) {
            reporter.report(.skanFailed, stage: .attribution, adId: "ad-\(index)")
        }
        #expect(reporter.buffer.count == ErrorReporter.maxBuffered && reporter.dropped == 5, "waiting for /config, the oldest go")
        await enableReports()
        #expect(await waitUntil { self.reports().count == ErrorReporter.maxBuffered })
        let batches = harness.server.requests(to: "/v2/error").compactMap(\.body)
        #expect(batches.allSatisfy { (($0["errors"] as? [Any])?.count ?? 0) <= ErrorReporter.maxBatch }, "at most maxBatch reports per batch")
        #expect(batches.compactMap { $0["dropped"] as? Int }.reduce(0, +) == 5, "the dropped count goes once")
    }

    // MARK: The ad's faults

    @Test func theCreativesFailuresAreToldApartBehindTheSameVastCode() async throws {
        await enableReports()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        let terminated = try loadedAd(Fixtures.overlayAd(id: "o-er-t"), in: ads)
        try terminated.show(in: harness.player.view)
        terminated.bridge.webViewWebContentProcessDidTerminate(terminated.bridge.webView)
        let pageError = try loadedAd(Fixtures.ad(id: "p-er-e"), in: ads)
        pageError.bridge.receive(["adId": pageError.id, "type": "ad.error", "code": 405], from: sender)
        #expect(await waitUntil { self.reports().count == 2 })
        let process = try #require(reports("frame.process_terminated").first)
        #expect(process["vastCode"] as? Int == 405 && process["stage"] as? String == "playback" && process["recovery"] as? String == "ad_ended_failed")
        #expect(process["adId"] as? String == "o-er-t" && process["sessionId"] as? String == ads.sessionId)
        let creative = try #require(reports("ad.creative_failed").first)
        #expect(creative["stage"] as? String == "load" && creative["recovery"] as? String == "ad_dropped_before_show", "failed while waiting to be shown")
    }

    @Test func aPageThatBreaksTheMessageContractIsReportedOncePerAd() async throws {
        await enableReports()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        let ad = try loadedAd(Fixtures.ad(id: "p-er-p"), in: ads)
        ad.bridge.receive(["adId": "someone-else", "type": "ad.loaded"], from: sender)
        ad.bridge.receive(["type": "ad.loaded"], from: sender)
        ad.bridge.receive(["adId": ad.id, "type": "ad.fromTheFuture"], from: sender)   // a newer page: not a violation
        ad.bridge.receive(["adId": "x"], from: FrameBridge.Sender(isMainFrame: false, scheme: "https", host: "creative.test", port: 443))
        #expect(await waitUntil { !self.reports("frame.protocol_violation").isEmpty })
        await sleepMs(50)
        let violations = reports("frame.protocol_violation")
        #expect(violations.count == 1 && violations.first?["detail"] as? String == "envelope", "\(violations)")
    }

    @Test func aPresentationUIKitNeverCompletesIsReported() async throws {
        await enableReports()
        VideoAd.presentationTimeout = 0.1
        defer { VideoAd.presentationTimeout = 2 }
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        let ad = try loadedAd(Fixtures.linearAd(id: "v-er-p"), in: ads)
        try ad.show(from: window.root)
        #expect(await waitUntil { !self.reports("ad.presentation_failed").isEmpty })
        #expect(reports("ad.presentation_failed").first?["recovery"] as? String == "ad_ended_failed")
    }

    @Test func aFailedSKAdNetworkStepCarriesTheStepAndTheErrorCodeOnly() async throws {
        await enableReports()
        struct Refused: LocalizedError {
            var errorDescription: String? { "contains user-secret-2" }
        }
        harness.skAdNetwork.onStart = { throw Refused() }
        let impression = SKAdNetworkImpression(skan: try #require(Fixtures.descriptor(Fixtures.installAd(Fixtures.ad(id: "p-er-s"), itunesItem: "1")).skan), adId: "p-er-s")
        impression.start()
        #expect(await waitUntil { !self.reports("skan.failed").isEmpty })
        let report = try #require(reports("skan.failed").first)
        #expect(report["detail"] as? String == "start" && report["stage"] as? String == "attribution")
        #expect((report["underlying"] as? [String: Any])?["domain"] is String)
        let raw = String(bytes: try #require(harness.server.requests(to: "/v2/error").first).rawBody, encoding: .utf8) ?? ""
        #expect(!raw.contains("user-secret-2"), "never the error's text")
    }

    // MARK: Bounds and accuracy

    @Test func aNoFillReasonTheSDKDoesNotKnowNeverLeavesTheDevice() async throws {
        await enableReports()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        let free = "contact secret@example.com at https://evil.test/x"
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill(free)))
        _ = try? await ads.format(.pause)
        reporter.report(.skanFailed, stage: .attribution, detail: "start")   // any fault after it carries the history
        #expect(await waitUntil { !self.reports("skan.failed").isEmpty })
        let raw = String(bytes: try #require(harness.server.requests(to: "/v2/error").last).rawBody, encoding: .utf8) ?? ""
        #expect(!raw.contains("secret@example.com") && !raw.contains("evil.test"), "the server's free text stays on the device")
        let history = (reports("skan.failed").first?["history"] as? [[String: Any]]) ?? []
        let reasons = history.compactMap { ($0["state"] as? [String: Any])?["reason"] as? String }
        #expect(reasons.contains("other"), "an unknown reason is \"other\": \(reasons)")
    }

    @Test func longIdsAreCappedAndABatchStaysWithinItsByteBudget() async throws {
        await enableReports()
        let long = String(repeating: "a", count: 10_000)
        for index in 0..<60 {
            reporter.report(.skanFailed, stage: .attribution, requestId: long, sessionId: long, adId: "\(index)" + long, detail: long)
        }
        #expect(await waitUntil { self.reports().count == 60 })
        #expect(reports().allSatisfy { report in
            ["requestId", "sessionId", "adId", "detail"].allSatisfy { ((report[$0] as? String)?.count ?? 0) <= ErrorReporter.maxFieldLength }
        }, "every string capped")
        let sizes = harness.server.requests(to: "/v2/error").map(\.rawBody.count)
        #expect(sizes.allSatisfy { $0 <= ErrorReporter.maxBatchBytes + 1024 }, "each request within the budget plus its envelope: \(sizes)")
    }

    @Test func aCharacterWithThousandsOfCombiningMarksIsCappedByBytes() async throws {
        let heavy = "e" + String(repeating: "\u{0301}", count: 5_000)   // one character, about 10 KB
        #expect(heavy.count == 1 && heavy.utf8.count > 10_000)
        #expect(ErrorReporter.capped(heavy).utf8.count <= ErrorReporter.maxFieldLength)
        #expect(ErrorReporter.capped("short") == "short")
        await enableReports()
        DebugReporter.shared.event("ad.shown", adId: heavy, state: ["format": .string(heavy)])
        for _ in 0..<20 {
            reporter.report(.skanFailed, stage: .attribution, requestId: heavy, sessionId: heavy, adId: heavy, detail: heavy)
        }
        #expect(await waitUntil { self.reports().count == 20 })
        let report = try #require(reports().first)
        #expect(["requestId", "sessionId", "adId", "detail"].allSatisfy { ((report[$0] as? String)?.utf8.count ?? 0) <= ErrorReporter.maxFieldLength })
        let moment = (report["history"] as? [[String: Any]])?.first { $0["name"] as? String == "ad.shown" }
        #expect(((moment?["adId"] as? String)?.utf8.count ?? 0) <= ErrorReporter.maxFieldLength)
        #expect((((moment?["state"] as? [String: Any])?["format"] as? String)?.utf8.count ?? 0) <= ErrorReporter.maxFieldLength)
        let sizes = harness.server.requests(to: "/v2/error").map(\.rawBody.count)
        #expect(sizes.allSatisfy { $0 <= ErrorReporter.maxBatchBytes + 1024 }, "within the batch budget: \(sizes)")
    }

    @Test func aFailedConfigIsReportedWithTheIdOfItsRequest() async throws {
        harness.server.on("/v2/config", .failure(.timedOut))
        _ = await harness.initialize()
        let sent = harness.server.requests(to: "/v2/config").compactMap { $0.body?["requestId"] as? String }
        #expect(sent.count == 1, "one attempt")
        #expect(reporter.buffer.first?.requestId == sent.first)
    }

    @Test func anExpiredHeldAdIsNotCountedAsKept() async throws {
        await enableReports()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        harness.serve(Fixtures.ad(id: "img-er-x", expires: 30_000))
        _ = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        var failing = StubServer.Response.json(Fixtures.errors("internal", status: 500), status: 500)
        failing.gate = gate
        harness.server.on("/v2/video/ads", failing)
        let call = Task { try? await ads.format(.pause) }
        #expect(await waitUntil { self.harness.adsRequests.count == 2 })
        advanceClock(by: 31)   // the held ad expires while the request is out
        gate.open()
        #expect(await call.value == nil, "no valid ad to fall back to")
        #expect(await waitUntil { !self.reports("ads.request_failed").isEmpty })
        #expect(reports("ads.request_failed").first?["recovery"] as? String == "no_ad")
    }

    @Test func aPageThatCannotLoadCarriesTheSystemErrorsDomainAndCode() async throws {
        await enableReports()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        let ad = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.ad(id: "p-er-l")), owner: ads)
        ad.bridge.load()
        ad.bridge.webView(ad.bridge.webView, didFailProvisionalNavigation: nil, withError: URLError(.cannotFindHost))
        #expect(await waitUntil { !self.reports("frame.load_failed").isEmpty })
        let underlying = reports("frame.load_failed").first?["underlying"] as? [String: Any]
        #expect(underlying?["domain"] as? String == NSURLErrorDomain && underlying?["code"] as? Int == URLError.cannotFindHost.rawValue)
    }

    // MARK: Integration mistakes

    @Test func integrationMistakesAreReportedOnceTheServerAllowsIt() async throws {
        Environment.assertionFailure = { _ in }
        _ = VideoAds(content: .init(id: "v", language: "en"))   // before initialize: waits in memory
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportErrors: true)))
        _ = await KontextVideo.shared.initialize(with: KontextVideo.Configuration(publisherToken: "", adServerURL: harness.server.baseURL))
        _ = harness.player.ads(for: .init(id: "", language: "en"))
        #expect(await waitUntil { self.reports().count == 3 })
        #expect(reports("integration.not_initialized").first?["detail"] as? String == "VideoAds(content:)")
        #expect(reports("integration.empty_token").count == 1)
        #expect(reports("integration.bad_content").first?["detail"] as? String == "id is empty")
    }

    /// `resetForTesting` without the harness's stub server teardown, between two initializations in one test.
    private func sdkReset() {
        KontextVideo.shared.resetForTesting()
    }
}
}
