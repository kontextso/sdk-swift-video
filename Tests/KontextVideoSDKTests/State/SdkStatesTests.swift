import Foundation
@testable import KontextVideoSDK
import Testing

/// Every move of the SDK's own state, and what the error and debug reporters do in each state, end to end through
/// the public calls and the stub server: the behavior `SdkState` and `SdkLifecycle` must keep.
extension SerialSuites {
@Suite
@MainActor
struct SdkStatesTests {
    private let harness = SDKHarness()
    private var sdk: KontextVideo { KontextVideo.shared }
    private var errors: ErrorReporter { ErrorReporter.shared }

    /// `/config` held until the returned gate opens, then answering `body`.
    private func heldConfig(_ body: [String: Any]) -> StubServer.Gate {
        let gate = StubServer.Gate()
        var response = StubServer.Response.json(body)
        response.gate = gate
        harness.server.on("/v2/config", response)
        return gate
    }

    private func report(_ detail: String = "x") {
        errors.report(.creativeFailed, detail: detail)
    }

    private func errorReports() -> [[String: Any]] {
        harness.server.requests(to: "/v2/error").flatMap { ($0.body?["errors"] as? [[String: Any]]) ?? [] }
    }

    private func debugNames() -> [String] {
        harness.server.requests(to: "/v2/debug")
            .flatMap { ($0.body?["events"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["name"] as? String }
    }

    /// A `format(_:)` call, its outcome as a `VideoAdError` or `nil` for an ad.
    private func formatError() async -> VideoAdError? {
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        do {
            _ = try await ads.format(.pause)
            return nil
        } catch {
            return error as? VideoAdError
        }
    }

    /// A second `initialize` changes nothing: no `/config`, the same state, the first configuration.
    private func expectSecondInitializeIgnored() async {
        let before = sdk.state
        let configs = harness.server.requests(to: "/v2/config").count
        sdk.initialize(with: KontextVideo.Configuration(publisherToken: "other", adServerURL: harness.server.baseURL), completion: nil)
        await sleepMs(30)
        #expect(sdk.state == before)
        #expect(sdk.configuration?.publisherToken == "test-dev")
        #expect(harness.server.requests(to: "/v2/config").count == configs)
    }

    // MARK: The SDK's moves

    @Test func notInitializedMovesToInitializingThenEnabled() async {
        #expect(sdk.state == .notInitialized && !sdk.isInitialized && sdk.disabledReason == nil)
        let gate = heldConfig(Fixtures.initEnabled())
        var heard: KontextVideo.State?
        sdk.initialize(with: harness.configuration) { heard = $0 }
        #expect(sdk.state == .initializing && sdk.isInitialized)
        #expect(await waitUntil { harness.server.requests(to: "/v2/config").count == 1 })
        await expectSecondInitializeIgnored()
        gate.open()
        #expect(await waitUntil { heard != nil })
        #expect(heard == .enabled && sdk.state == .enabled && sdk.disabledReason == nil)
        await expectSecondInitializeIgnored()
    }

    @Test func initializingMovesToDisabledWhenConfigSaysSo() async {
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        #expect(await harness.initialize() == .disabled(reason: "publisherDisabled"))
        #expect(sdk.disabledReason == "publisherDisabled" && sdk.isInitialized)
        await expectSecondInitializeIgnored()
        guard case .disabled? = await formatError() else { Issue.record("expected disabled"); return }
        #expect(harness.server.requests(to: "/v2/config").count == 1, "no retry: disabled is final")
    }

    @Test func initializingMovesToFailedAndTheNextAdsRequestMovesItBackToInitializing() async throws {
        harness.server.on("/v2/config", .failure(.timedOut))
        #expect(await harness.initialize() == .failed)
        #expect(sdk.isInitialized && sdk.disabledReason == nil)
        await expectSecondInitializeIgnored()
        // A retry that fails again: back to failed.
        #expect(try await sdk.waitUntilEnabled() == false)
        #expect(sdk.state == .failed && harness.server.requests(to: "/v2/config").count == 2)
        // A retry held by the server: initializing until it answers, then enabled.
        let gate = heldConfig(Fixtures.initEnabled())
        let retry = Task { try await sdk.waitUntilEnabled() }
        #expect(await waitUntil { sdk.state == .initializing })
        gate.open()
        #expect(try await retry.value)
        #expect(sdk.state == .enabled && harness.server.requests(to: "/v2/config").count == 3)
    }

    @Test func failedMovesToDisabledThroughTheRetry() async throws {
        harness.server.on("/v2/config", .failure(.timedOut))
        #expect(await harness.initialize() == .failed)
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        #expect(try await sdk.waitUntilEnabled() == false)
        #expect(sdk.state == .disabled(reason: "publisherDisabled"))
    }

    @Test func aKillSwitchInAnAdsAnswerMovesEnabledToDisabled() async {
        #expect(await harness.initialize() == .enabled)
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("killed")))
        guard case .disabled(let reason)? = await formatError() else { Issue.record("expected disabled"); return }
        #expect(reason == "killed" && sdk.state == .disabled(reason: "killed"))
        await expectSecondInitializeIgnored()
        // Another answer in flight meanwhile may carry another reason: the last one stays.
        sdk.disable(reason: "killed")
        #expect(sdk.state == .disabled(reason: "killed"))
        sdk.disable(reason: "other")
        #expect(sdk.state == .disabled(reason: "other"))
    }

    // MARK: Error reports across the states

    @Test func errorReportsWaitWhileNotInitializedAndInitializingThenLeaveOnceConfigTurnsThemOn() async {
        report("before")
        #expect(errors.mode == .pending)
        let gate = heldConfig(Fixtures.initEnabled(reportErrors: true))
        var heard: KontextVideo.State?
        sdk.initialize(with: harness.configuration) { heard = $0 }
        report("during")
        await sleepMs(30)
        #expect(errors.mode == .pending && errors.buffer.count == 2)
        #expect(harness.server.requests(to: "/v2/error").isEmpty)
        gate.open()
        #expect(await waitUntil { heard != nil })
        #expect(errors.mode == .on)
        #expect(await waitUntil { self.errorReports().count == 2 })
        #expect(errorReports().map { $0["detail"] as? String } == ["before", "during"])
    }

    @Test func errorReportsWaitWhileFailedAndLeaveOnceARetryTurnsThemOn() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        #expect(await harness.initialize() == .failed)
        report("failed")
        #expect(errors.mode == .pending && errors.buffer.map(\.code) == ["config.failed", "ad.creative_failed"])
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportErrors: true)))
        harness.serve(Fixtures.ad(id: "img-st1"))
        #expect(await formatError() == nil)
        #expect(await waitUntil { self.errorReports().count == 2 })
    }

    @Test func errorReportsAreDroppedWhenConfigDisablesOrLeavesThemOut() async {
        report()
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        _ = await harness.initialize()
        report()
        #expect(errors.mode == .off && errors.buffer.isEmpty)
        sdk.resetForTesting()
        harness.server.on("/v2/config", .json(Fixtures.initEnabled()))
        report()
        _ = await harness.initialize()
        report()
        await sleepMs(50)
        #expect(errors.mode == .off && errors.buffer.isEmpty)
        #expect(harness.server.requests(to: "/v2/error").isEmpty)
    }

    @Test func errorReportsStayOnAfterTheKillSwitch() async {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportErrors: true)))
        _ = await harness.initialize()
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("killed")))
        _ = await formatError()
        #expect(sdk.state == .disabled(reason: "killed") && errors.mode == .on)
        report("after")
        #expect(await waitUntil { self.errorReports().contains { $0["detail"] as? String == "after" } })
    }

    // MARK: Debug reports across the states

    @Test func debugEventsLeaveOnlyOnceConfigAsksAndStillAfterTheKillSwitch() async {
        DebugReporter.shared.event("before")
        #expect(!DebugReporter.shared.isEnabled)
        let gate = heldConfig(Fixtures.initEnabled(reportDebug: true))
        var heard: KontextVideo.State?
        sdk.initialize(with: harness.configuration) { heard = $0 }
        DebugReporter.shared.event("during")
        #expect(!DebugReporter.shared.isEnabled)
        gate.open()
        #expect(await waitUntil { heard != nil })
        #expect(DebugReporter.shared.isEnabled)
        #expect(await waitUntil { self.debugNames().contains("config.response") })
        harness.server.on("/v2/video/ads", .json(Fixtures.disabled("killed")))
        _ = await formatError()
        #expect(sdk.state == .disabled(reason: "killed"))
        #expect(DebugReporter.shared.isEnabled, "on after the kill switch")
        DebugReporter.shared.event("after")
        #expect(await waitUntil { self.debugNames().contains("after") })
        #expect(!debugNames().contains { $0 == "before" || $0 == "during" }, "nothing from before /config answered")
    }

    @Test func debugEventsStayOffWhenConfigFailsDisablesOrLeavesThemOut() async {
        harness.server.on("/v2/config", .failure(.timedOut))
        #expect(await harness.initialize() == .failed)
        #expect(!DebugReporter.shared.isEnabled)
        sdk.resetForTesting()
        harness.server.on("/v2/config", .json(Fixtures.disabled("publisherDisabled")))
        _ = await harness.initialize()
        #expect(!DebugReporter.shared.isEnabled)
        sdk.resetForTesting()
        harness.server.on("/v2/config", .json(Fixtures.initEnabled()))
        _ = await harness.initialize()
        #expect(!DebugReporter.shared.isEnabled)
        DebugReporter.shared.event("tick")
        await sleepMs(250)
        #expect(harness.server.requests(to: "/v2/debug").isEmpty)
    }
}
}
