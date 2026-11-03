import Foundation
@testable import KontextVideoSDK
import Testing

/// Every SDK session stops a request after ten redirects, the SDK's own requests and beacons alike.
@Suite
struct RedirectLimitTests {
    @Test func aTaskFollowsTenRedirectsAndNoMore() {
        let limit = RedirectLimit()
        for hop in 1...RedirectLimit.maxRedirects {
            #expect(limit.mayFollow(1), "redirect \(hop)")
        }
        #expect(!limit.mayFollow(1), "the eleventh is not followed")
    }

    @Test func eachTaskCountsItsOwnAndAFinishedTaskIsForgotten() {
        let limit = RedirectLimit()
        for _ in 1...RedirectLimit.maxRedirects { _ = limit.mayFollow(1) }
        #expect(limit.mayFollow(2), "another task starts at zero")
        limit.forget(1)
        #expect(limit.mayFollow(1), "a task id reused after the end starts again")
    }

    @MainActor
    @Test func theSdksSessionsAndTheBeaconSessionLimitRedirects() {
        #expect(Environment.makeSession().delegate is RedirectLimit)
        #expect(BeaconTransport.session(over: Environment.makeSession()).delegate is RedirectLimit)
    }
}
