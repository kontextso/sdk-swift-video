import Foundation
import UIKit

/// The user agent an ads request carries: the WebView's `navigator.userAgent`, read once through KontextKit
/// (`Environment.userAgent`) and shared by every caller, waited for at most `userAgentWait`, else a fallback of
/// the same shape.
@MainActor
enum UserAgent {
    /// The one lookup in flight, or done with a value: KontextKit makes a WebView for every call until it has
    /// cached the answer, so the SDK asks once and every request waits for that.
    static var lookup: Task<String?, Never>?

    /// How long a request waits for the lookup. On a cold device the WebView's first answer can take tens of
    /// seconds, and the request's own timeout starts only once it is built: past this, the request goes with
    /// `fallbackUserAgent` and the lookup goes on for the requests after it. A constant in spirit; a
    /// variable so the tests can shorten it.
    static var userAgentWait = defaultUserAgentWait
    nonisolated static let defaultUserAgentWait: TimeInterval = 2

    /// The shape of a WebView's user agent on iOS, from the OS version and the device kind, for a request
    /// that cannot wait for the real one.
    static var fallbackUserAgent: String {
        let device = UIDevice.current
        let version = device.systemVersion.replacingOccurrences(of: ".", with: "_")
        let platform = device.userInterfaceIdiom == .pad ? "iPad; CPU OS \(version)" : "\(device.model); CPU iPhone OS \(version)"
        return "Mozilla/5.0 (\(platform) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    }

    /// Starts the lookup unless one is in flight or has a value; `/config` calls it so the first request
    /// rarely waits.
    @discardableResult
    static func startLookup() -> Task<String?, Never> {
        let task = lookup ?? Task { await Environment.userAgent() }
        lookup = task
        return task
    }

    /// Waits for the user agent, at most `userAgentWait`, then takes `fallbackUserAgent`. A cancelled caller
    /// (a request whose `VideoAds` was destroyed) stops waiting at once, with no user agent, and the lookup
    /// goes on for the others; the request then finds its owner gone and sends nothing. A lookup that found
    /// none is tried again by the next caller.
    static func requestUserAgent() async -> String? {
        let task = startLookup()
        let wait = userAgentWait
        do {
            guard let userAgent = try await awaitShared(task, timeout: wait) else {
                Logger.debug("user agent not ready within \(wait) s; this request carries the fallback")
                return fallbackUserAgent
            }
            if userAgent == nil, lookup == task { lookup = nil }
            return userAgent
        } catch {
            return nil
        }
    }

    /// Back to no lookup and the default wait. Tests only: `Environment.reset()` calls it.
    static func resetForTesting() {
        lookup = nil
        userAgentWait = defaultUserAgentWait
    }
}
