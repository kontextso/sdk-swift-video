import Foundation
@testable import KontextVideoSDK
import Testing

/// The shared instance: initialising once, the `/config` outcomes, waiting and retrying, the kill switch,
/// the targeting setters, and the rules it enforces across every `VideoAds`.
extension SerialSuites {
@Suite
@MainActor
struct KontextVideoTests {
    private let harness = SDKHarness()
    private var sdk: KontextVideo { KontextVideo.shared }

    // MARK: initialize

    @Test func startsNotInitialized() {
        #expect(sdk.state == .notInitialized)
        #expect(sdk.isInitialized == false)
        #expect(sdk.configuration == nil)
    }

    @Test func initializeStoresTheConfigurationAndBecomesEnabled() async {
        let state = await harness.initialize()
        #expect(state == .enabled)
        #expect(sdk.state == .enabled)
        #expect(sdk.isInitialized)
        #expect(sdk.configuration?.publisherToken == "test-dev")
        let request = harness.server.requests(to: "/v2/config").first
        #expect(request?.body?["publisherToken"] as? String == "test-dev")
        #expect(request?.body?["installId"] as? String == KontextVideo.installId)
    }

    @Test func fireAndForgetFormReportsThroughTheCompletion() async {
        var reported: KontextVideo.State?
        sdk.initialize(with: harness.configuration) { reported = $0 }
        #expect(sdk.state == .initializing)
        #expect(await waitUntil { reported != nil })
        #expect(reported == .enabled)
    }

    @Test func aResetDuringInitializeIsNotUndoneByTheCancelledRequest() async {
        var slow = StubServer.Response.json(Fixtures.initEnabled())
        slow.delay = 0.2
        harness.server.on("/v2/config", slow)
        var reported: KontextVideo.State?
        sdk.initialize(with: harness.configuration) { reported = $0 }
        await sleepMs(30)
        sdk.resetForTesting()
        await sleepMs(300)
        #expect(sdk.state == .notInitialized, "the cancelled request neither fails nor enables what was reset")
        #expect(reported == nil, "and its completion never fires")
    }

    @Test func anUnusableConfigurationStopsADebugBuild() {
        #expect(harness.configuration.problems.isEmpty)
        #expect(KontextVideo.Configuration(publisherToken: "p", adServerURL: URL(string: "http://localhost:5175")!).problems.isEmpty, "a local mock")
        #expect(KontextVideo.Configuration(publisherToken: "").problems == ["publisherToken is empty"])
        #expect(KontextVideo.Configuration(publisherToken: "p", adServerURL: URL(string: "server.megabrain.co")!).problems.count == 1)
        var assertions: [String] = []
        Environment.assertionFailure = { assertions.append($0) }
        sdk.initialize(with: KontextVideo.Configuration(publisherToken: "", adServerURL: harness.server.baseURL))
        #expect(assertions == ["KontextVideo.Configuration: publisherToken is empty"])
    }

    @Test func anEmptyUserIdStopsADebugBuild() {
        var assertions: [String] = []
        Environment.assertionFailure = { assertions.append($0) }
        sdk.user = KontextVideo.User(id: "u1", email: "")
        #expect(assertions.isEmpty, "an empty email is left out with a warning")
        sdk.user = KontextVideo.User(id: "")
        #expect(assertions == ["KontextVideo.User: id is empty"])
    }

    @Test func secondInitializeIsIgnored() async {
        _ = await harness.initialize()
        var completions = 0
        sdk.initialize(with: KontextVideo.Configuration(publisherToken: "other", adServerURL: harness.server.baseURL)) { _ in completions += 1 }
        await sleepMs(50)
        #expect(sdk.configuration?.publisherToken == "test-dev", "the first configuration stays")
        #expect(completions == 0, "an ignored call runs no completion")
        #expect(harness.server.requests(to: "/v2/config").count == 1)
        let again = await sdk.initialize(with: harness.configuration)
        #expect(again == .enabled, "the async form answers with the state the first call produced")
    }

    @Test func initializeAppliesTheLogLevel() async {
        _ = await harness.initialize()
        #expect(Logger.level == .none)
    }

    @Test func disabledByInitIsFinalForTheLaunch() async {
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        let state = await harness.initialize()
        #expect(state == .disabled(reason: "publisherDisabled"))
        #expect(await sdk.waitUntilEnabled() == false)
    }

    @Test func failedInitAfterTheRetryIsFailed() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        let state = await harness.initialize()
        #expect(state == .failed)
        #expect(harness.server.requests(to: "/v2/config").count == 2, "one retry")
        #expect(await sdk.waitUntilEnabled() == false)
    }

    @Test func waitUntilEnabledWaitsForInitInFlight() async {
        harness.server.on("/v2/config") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.initEnabled()), delay: 0.15) }
        sdk.initialize(with: harness.configuration, completion: nil)
        let started = Date()
        let enabled = await sdk.waitUntilEnabled()
        #expect(enabled)
        #expect(Date().timeIntervalSince(started) >= 0.1)
    }

    @Test func aFailedInitIsRetriedByTheNextRequestAtOnce() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        _ = await harness.initialize()
        #expect(harness.server.requests(to: "/v2/config").count == 2, "10 s timeout, one retry")
        harness.server.on("/v2/config", .json(Fixtures.initEnabled()))
        #expect(await sdk.waitUntilEnabled(), "waitUntilEnabled retries a failed /config itself, no waiting period")
        #expect(sdk.state == .enabled)
        #expect(harness.server.requests(to: "/v2/config").count == 3)
    }

    @Test func everyRequestRetriesAFailedInitAgain() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        _ = await harness.initialize()
        #expect(await sdk.waitUntilEnabled() == false)
        #expect(await sdk.waitUntilEnabled() == false)
        #expect(harness.server.requests(to: "/v2/config").count == 6, "two more attempts, each with its own retry")
        #expect(sdk.state == .failed)
    }

    @Test func aLoadRetriesADueInit() async throws {
        harness.server.on("/v2/config", .failure(.timedOut))
        _ = await harness.initialize()
        harness.server.on("/v2/config", .json(Fixtures.initEnabled()))
        let ads = harness.player.ads(for: .init(id: "v", language: "en"))
        harness.serve(Fixtures.ad(id: "img-retry"))
        _ = try? await ads.format(.pause).load()
        #expect(sdk.state == .enabled)
    }

    @Test func disableFromAnAdsResponseIsTheSameKillSwitch() async {
        _ = await harness.initialize()
        sdk.disable(reason: "appVersionDisabled")
        #expect(sdk.state == .disabled(reason: "appVersionDisabled"))
        #expect(await sdk.waitUntilEnabled() == false)
    }

    @Test func reportDebugEnablesTheReporter() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        #expect(sdk.reportDebug)
        #expect(DebugReporter.shared.isEnabled)
    }

    // MARK: Programmer errors

    @Test func videoAdsBeforeInitializeAsserts() {
        var messages: [String] = []
        Environment.assertionFailure = { messages.append($0) }
        _ = harness.player.ads(for: .init(id: "v", language: "en"))
        #expect(messages.count == 1)
        #expect(messages.first?.contains("initialize(with:)") == true)
    }

    @Test func requireInitializedIsQuietOnceInitialized() async {
        _ = await harness.initialize()
        var messages: [String] = []
        Environment.assertionFailure = { messages.append($0) }
        #expect(sdk.requireInitialized("x"))
        #expect(messages.isEmpty)
    }

    // MARK: Targeting

    @Test func targetingSettersAreStoredAndCompared() async {
        _ = await harness.initialize()
        sdk.user = KontextVideo.User(id: "u1")
        sdk.regulatory = KontextVideo.Regulatory(coppa: true)
        sdk.variantId = "b"
        #expect(sdk.user?.id == "u1")
        #expect(sdk.regulatory?.coppa == true)
        #expect(sdk.variantId == "b")
        sdk.user = nil
        #expect(sdk.user == nil)
    }

    @Test func installIdIsStableAndAUUID() {
        let id = KontextVideo.installId
        #expect(UUID(uuidString: id) != nil)
        #expect(KontextVideo.installId == id)
        #expect(KontextVideo.version == SDKInfo.version)
    }

    // MARK: The /config retry

    @Test func configRequestRetriesOnceOnARetryableFailureWithTheSameRequestId() async throws {
        var calls = 0
        harness.server.on("/v2/config") { _ in
            calls += 1
            return calls == 1 ? .failure(.timedOut) : .json(Fixtures.initEnabled(reportDebug: true))
        }
        KontextVideo.configRetryDelay = 0.001
        let request = ConfigRequest.make(configuration: KontextVideo.Configuration(publisherToken: "t", adServerURL: harness.server.baseURL), installId: "i")
        let response = try await KontextVideo.sendConfigRequest(request, client: APIClient(baseURL: harness.server.baseURL))
        guard case .enabled(let reportDebug) = response else { Issue.record("expected enabled"); return }
        #expect(reportDebug)
        let bodies = harness.server.requests(to: "/v2/config").compactMap(\.body)
        #expect(bodies.count == 2)
        #expect(bodies[0]["requestId"] as? String != bodies[1]["requestId"] as? String, "each request its own trace id, the retry included")
        #expect(bodies[0]["installId"] as? String == bodies[1]["installId"] as? String && bodies[1]["publisherToken"] as? String == "t", "the rest as it was")
    }

    @Test func configRequestDoesNotRetryAClientError() async {
        harness.server.on("/v2/config", .json(Fixtures.errors("invalidRequest"), status: 400))
        let request = ConfigRequest.make(configuration: KontextVideo.Configuration(publisherToken: "t", adServerURL: harness.server.baseURL), installId: "i")
        await #expect(throws: APIError.self) { try await KontextVideo.sendConfigRequest(request, client: APIClient(baseURL: harness.server.baseURL)) }
        #expect(harness.server.requests(to: "/v2/config").count == 1)
    }

    @Test func configRequestGivesUpAfterTheSecondFailure() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        KontextVideo.configRetryDelay = 0.001
        let request = ConfigRequest.make(configuration: KontextVideo.Configuration(publisherToken: "t", adServerURL: harness.server.baseURL), installId: "i")
        await #expect(throws: APIError.self) { try await KontextVideo.sendConfigRequest(request, client: APIClient(baseURL: harness.server.baseURL)) }
        #expect(harness.server.requests(to: "/v2/config").count == 2)
    }
}
}
