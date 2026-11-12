import KontextVideoSDK
import Testing

/// What an app can do with the SDK's public API alone: no `@testable` here, so this file sees only what an
/// app sees.
@MainActor
struct PublicSurfaceTests {
    @Test func anAppCanMakeThePricesAndClicksItsOwnTestsNeed() {
        let price = VideoAd.Price(value: 2.5, currency: "USD")
        #expect(price.value >= 2 && price.currency == "USD")
        #expect(VideoAd.Click(area: .endCard).area == .endCard)
    }

    @Test func anAppCanReadTheSDKStateAtAnyTime() {
        // Whatever the other suites left: readable, and one of the documented states.
        switch KontextVideo.shared.state {
        case .notInitialized, .initializing, .enabled, .disabled, .failed: break
        }
    }

    @Test func anAppCanTellWhyARequestFailedAndCompareErrors() {
        // Exhaustive without a default: the app sees every reason, and a new one would be a compile error.
        func advice(_ failure: VideoAdError.RequestFailure) -> String {
            switch failure {
            case .offline: return "when online"
            case .timedOut: return "later"
            case .server(let status): return "later (\(status))"
            case .badResponse: return "report"
            case .missingUser: return "set KontextVideo.shared.user"
            }
        }
        let error: Error = VideoAdError.request(.server(status: 503))
        guard case VideoAdError.request(let failure)? = error as? VideoAdError else { Issue.record("not a request error"); return }
        #expect(advice(failure) == "later (503)")
        #expect(error as? VideoAdError == .request(.server(status: 503)))
        #expect(VideoAdError.noFill(reason: .noAdMatch) == .noFill(reason: .noAdMatch))
        #expect(VideoAdError.RequestFailure.offline.description == "offline")
    }
}
