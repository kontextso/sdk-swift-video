@testable import KontextVideoSDK
import Testing
import UIKit

/// The user agent's fallback, the shape of a WebView's on this device. The shared lookup and the wait are tested
/// through the ads request (`VideoAdsTests`).
@Suite
@MainActor
struct UserAgentTests {
    @Test func theFallbackHasAWebViewsShape() {
        let agent = UserAgent.fallbackUserAgent
        let version = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        #expect(agent.hasPrefix("Mozilla/5.0 ("))
        #expect(agent.contains("OS \(version) like Mac OS X"))
        #expect(agent.hasSuffix("AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"))
        #expect(agent.contains(UIDevice.current.userInterfaceIdiom == .pad ? "iPad; CPU OS" : "CPU iPhone OS"))
    }

    @Test func theDefaultWaitIsTwoSeconds() {
        #expect(UserAgent.defaultUserAgentWait == 2)
    }
}

/// The shared lookup's failure branches: a lookup that found none is tried again, and a cancelled caller stops
/// waiting at once while the lookup goes on. Serialized: it replaces `Environment.userAgent`.
extension SerialSuites {
@Suite
@MainActor
struct UserAgentLookupTests {
    init() { SDKHarness.reset() }

    @Test func aLookupThatFoundNoneIsTriedAgainByTheNextCaller() async {
        var lookups = 0
        Environment.userAgent = {
            lookups += 1
            return lookups == 1 ? nil : "UA"
        }
        #expect(await UserAgent.requestUserAgent() == nil)
        #expect(await UserAgent.requestUserAgent() == "UA")
        #expect(lookups == 2)
    }

    @Test func aCancelledCallerReturnsAtOnceAndTheLookupGoesOn() async {
        UserAgent.userAgentWait = 60
        var lookups = 0
        var release: CheckedContinuation<Void, Never>?
        Environment.userAgent = {
            lookups += 1
            await withCheckedContinuation { release = $0 }
            return "UA"
        }
        let caller = Task { await UserAgent.requestUserAgent() }
        #expect(await waitUntil { release != nil })
        caller.cancel()
        #expect(await caller.value == nil, "cancelled before the lookup answered")
        release?.resume()
        #expect(await UserAgent.requestUserAgent() == "UA", "the same lookup answers the next caller")
        #expect(lookups == 1)
    }
}
}
