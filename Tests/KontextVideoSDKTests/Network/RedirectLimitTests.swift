import Foundation
@testable import KontextVideoSDK
import Testing

/// Every SDK session stops a request after ten redirects, the SDK's own requests and beacons alike; only beacons
/// follow one from https to http, and nothing follows one to another scheme.
@Suite
struct RedirectLimitTests {
    @Test func aTaskFollowsTenRedirectsAndNoMore() {
        let limit = RedirectLimit(allowsDowngrade: false)
        for hop in 1...RedirectLimit.maxRedirects {
            #expect(limit.mayFollow(1), "redirect \(hop)")
        }
        #expect(!limit.mayFollow(1), "the eleventh is not followed")
    }

    @Test func eachTaskCountsItsOwnAndAFinishedTaskIsForgotten() {
        let limit = RedirectLimit(allowsDowngrade: false)
        for _ in 1...RedirectLimit.maxRedirects { _ = limit.mayFollow(1) }
        #expect(limit.mayFollow(2), "another task starts at zero")
        limit.forget(1)
        #expect(limit.mayFollow(1), "a task id reused after the end starts again")
    }

    @MainActor
    @Test func theSdksSessionsAndTheBeaconSessionLimitRedirects() {
        #expect((Environment.makeSession().delegate as? RedirectLimit)?.allowsDowngrade == false, "the API: no https to http")
        #expect((BeaconTransport.session(over: Environment.makeSession()).delegate as? RedirectLimit)?.allowsDowngrade == true,
                "beacons: tracking chains go through plain servers")
    }

    @Test func aDowngradeIsFollowedOnlyWhereAllowedAndOtherSchemesNever() {
        let https = URL(string: "https://a.test/x")
        let http = URL(string: "http://b.test/y")
        let rows: [(URL?, URL?, Bool, Bool)] = [
            (https, URL(string: "https://b.test/y"), false, true),
            (http, https, false, true),
            (http, http, false, true),
            (https, http, false, false),
            (https, http, true, true),
            (https, URL(string: "HTTP://b.test/y"), false, false),
            (https, URL(string: "ftp://b.test/y"), true, false),
            (https, URL(string: "myapp://open"), true, false),
            (https, nil, true, false),
        ]
        for (index, (from, to, allowsDowngrade, expected)) in rows.enumerated() {
            #expect(RedirectLimit.allows(from: from, to: to, allowsDowngrade: allowsDowngrade) == expected, "row \(index + 1)")
        }
    }

    @Test func theDelegateRefusesADowngradeOfAnAPIRequest() {
        let task = URLSession.shared.dataTask(with: URL(string: "https://a.test/v2/video/ads")!)
        let response = HTTPURLResponse(url: URL(string: "https://a.test/v2/video/ads")!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let downgrade = URLRequest(url: URL(string: "http://a.test/v2/video/ads")!)
        for (allowsDowngrade, expected) in [(false, false), (true, true)] {
            let followed = Followed()
            RedirectLimit(allowsDowngrade: allowsDowngrade).urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                                                       newRequest: downgrade) { followed.request = $0 }
            #expect((followed.request != nil) == expected, "allowsDowngrade \(allowsDowngrade)")
        }
    }

    /// What the delegate's completion handler was given; called synchronously here.
    final class Followed: @unchecked Sendable {
        var request: URLRequest?
    }
}
