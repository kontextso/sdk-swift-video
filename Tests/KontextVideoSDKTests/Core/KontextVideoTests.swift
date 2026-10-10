import Foundation
@testable import KontextVideoSDK
import Testing

/// The shared instance: initialising once, the `/init` outcomes, waiting and retrying, the kill switch,
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
        let request = harness.server.requests(to: "/v2/init").first
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

    @Test func secondInitializeIsIgnored() async {
        _ = await harness.initialize()
        var completions = 0
        sdk.initialize(with: KontextVideo.Configuration(publisherToken: "other", adServerURL: harness.server.baseURL)) { _ in completions += 1 }
        await sleepMs(50)
        #expect(sdk.configuration?.publisherToken == "test-dev", "the first configuration stays")
        #expect(completions == 0, "an ignored call runs no completion")
        #expect(harness.server.requests(to: "/v2/init").count == 1)
        let again = await sdk.initialize(with: harness.configuration)
        #expect(again == .enabled, "the async form answers with the state the first call produced")
    }

    @Test func initializeAppliesTheLogLevel() async {
        _ = await harness.initialize()
        #expect(Logger.level == .none)
    }

    @Test func disabledByInitIsFinalForTheLaunch() async {
        harness.server.on("/v2/init", .json(Fixtures.disabled("publisherDisabled")))
        let state = await harness.initialize()
        #expect(state == .disabled(reason: "publisherDisabled"))
        #expect(await sdk.waitUntilEnabled() == false)
    }

    @Test func failedInitAfterTheRetryIsFailed() async {
        harness.server.on("/v2/init", .failure(.timedOut))
        let state = await harness.initialize()
        #expect(state == .failed)
        #expect(harness.server.requests(to: "/v2/init").count == 2, "one retry")
        #expect(await sdk.waitUntilEnabled() == false)
    }

    @Test func waitUntilEnabledWaitsForInitInFlight() async {
        harness.server.on("/v2/init") { _ in StubServer.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: Fixtures.initEnabled()), delay: 0.15) }
        sdk.initialize(with: harness.configuration, completion: nil)
        let started = Date()
        let enabled = await sdk.waitUntilEnabled()
        #expect(enabled)
        #expect(Date().timeIntervalSince(started) >= 0.1)
    }

    @Test func retryIsNotDueBeforeTheInterval() async {
        harness.server.on("/v2/init", .failure(.timedOut))
        _ = await harness.initialize()
        harness.server.on("/v2/init", .json(Fixtures.initEnabled()))
        KontextVideo.initRetryInterval = 300
        sdk.retryInitIfDue()
        #expect(sdk.state == .failed)
        #expect(harness.server.requests(to: "/v2/init").count == 2)
    }

    @Test func retryWhenDueTriesAgainAndRecovers() async {
        harness.server.on("/v2/init", .failure(.timedOut))
        _ = await harness.initialize()
        harness.server.on("/v2/init", .json(Fixtures.initEnabled()))
        KontextVideo.initRetryInterval = 0
        #expect(await sdk.waitUntilEnabled(), "waitUntilEnabled retries a due /init itself")
        #expect(sdk.state == .enabled)
    }

    @Test func startOnAVideoAdsRetriesADueInit() async {
        harness.server.on("/v2/init", .failure(.timedOut))
        _ = await harness.initialize()
        harness.server.on("/v2/init", .json(Fixtures.initEnabled()))
        KontextVideo.initRetryInterval = 0
        let ads = VideoAds(content: .init(id: "v", language: "en"), player: harness.player)
        ads.start()
        #expect(await waitUntil { self.sdk.state == .enabled })
    }

    @Test func disableFromAnAdsResponseIsTheSameKillSwitch() async {
        _ = await harness.initialize()
        sdk.disable(reason: "appVersionDisabled")
        #expect(sdk.state == .disabled(reason: "appVersionDisabled"))
        #expect(await sdk.waitUntilEnabled() == false)
    }

    @Test func reportDebugEnablesTheReporter() async {
        harness.server.on("/v2/init", .json(Fixtures.initEnabled(reportDebug: true)))
        _ = await harness.initialize()
        #expect(sdk.reportDebug)
        #expect(DebugReporter.shared.isEnabled)
    }

    // MARK: Programmer errors

    @Test func videoAdsBeforeInitializeAsserts() {
        var messages: [String] = []
        Environment.assertionFailure = { messages.append($0) }
        _ = VideoAds(content: .init(id: "v", language: "en"), player: harness.player)
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
        #expect(KontextVideo.version == SDKInfo.current.version)
    }

    @Test func stopOthersStopsOnlyStartedVideoAdsOnTheSamePlayer() async {
        _ = await harness.initialize()
        let otherPlayer = TestPlayer()
        let a = VideoAds(content: .init(id: "a", language: "en"), player: harness.player)
        let b = VideoAds(content: .init(id: "b", language: "en"), player: harness.player)
        let c = VideoAds(content: .init(id: "c", language: "en"), player: otherPlayer)
        a.start()
        c.start()
        #expect(a.isStarted && c.isStarted)
        b.start()
        #expect(b.isStarted)
        #expect(a.isStarted == false, "displaced by b on the same player")
        #expect(c.isStarted, "another player is not affected")
        a.start()
        #expect(a.isStarted && !b.isStarted, "A, B, A is A active again")
    }
}
}
