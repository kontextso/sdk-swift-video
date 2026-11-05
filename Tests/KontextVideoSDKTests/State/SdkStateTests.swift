@testable import KontextVideoSDK
import Testing

/// The SDK's facts: the phase moves only as `SdkLifecycle` allows, the rest is recorded once or derived.
@Suite
@MainActor
struct SdkStateTests {
    @Test func startsNotInitializedWithNothingRecorded() {
        let state = SdkState()
        #expect(state.phase == .notInitialized)
        #expect(!state.isInitialized)
        #expect(state.disabledReason == nil)
        #expect(state.configuration == nil)
        #expect(state.isErrorReportingOn == nil, "error reports wait for /config")
        #expect(!state.isDebugReportingOn)
    }

    @Test func movesOnlyAsTheLifecycleAllows() {
        var state = SdkState()
        func move(_ next: KontextVideo.State) -> Bool { state.moveTo(next) }
        #expect(!move(.enabled), "not before /config")
        #expect(!move(.disabled(reason: "killed")), "no other process to disable it straight away")
        #expect(state.phase == .notInitialized)
        #expect(move(.initializing))
        #expect(state.isInitialized)
        #expect(move(.failed))
        #expect(!move(.disabled(reason: "killed")), "no kill switch while failed")
        #expect(move(.initializing))
        #expect(move(.enabled))
        #expect(move(.disabled(reason: "killed")))
        #expect(state.disabledReason == "killed")
        #expect(!move(.disabled(reason: "killed")), "the same reason is no move")
        #expect(move(.disabled(reason: "other")))
        #expect(!move(.initializing))
        #expect(!move(.enabled))
        #expect(state.phase == .disabled(reason: "other"))
        #expect(state.isInitialized)
    }

    @Test func theConfigurationIsRecordedOnce() {
        var state = SdkState()
        state.recordConfiguration(KontextVideo.Configuration(publisherToken: "first"))
        state.recordConfiguration(KontextVideo.Configuration(publisherToken: "second"))
        #expect(state.configuration?.publisherToken == "first")
    }

    @Test func errorReportingOffIsFinal() {
        var state = SdkState()
        state.recordErrorReporting(true)
        #expect(state.isErrorReportingOn == true)
        state.recordErrorReporting(false)
        state.recordErrorReporting(true)
        #expect(state.isErrorReportingOn == false)
    }

    @Test func debugReportingFollowsTheLastAnswer() {
        var state = SdkState()
        state.recordDebugReporting(true)
        #expect(state.isDebugReportingOn)
        state.recordDebugReporting(false)
        #expect(!state.isDebugReportingOn)
    }
}
