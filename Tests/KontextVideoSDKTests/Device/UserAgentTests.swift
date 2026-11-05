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
