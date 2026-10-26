import Foundation
import UIKit
import WebKit

/// The SDK's seams: what tests replace and production never touches. Every value has its production
/// default; `reset()` restores them all.
@MainActor
enum Environment {
    /// The session every request and beacon goes through.
    static var session: URLSession = .shared
    /// Where a loading WebView is parked so WebKit buffers its video, and where `show()` finds its presenter.
    static var keyWindow: @MainActor () -> UIWindow? = defaultKeyWindow
    /// Custom URL schemes the frame WebView can load, so a test serves a page from inside the process.
    static var schemeHandlers: [String: WKURLSchemeHandler] = [:]
    /// Opens a URL the page asked for; the completion says whether it could.
    static var openURL: @MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void = defaultOpenURL
    /// A programmer error: stops a debug build. Tests record it instead.
    static var assertionFailure: (String) -> Void = { Swift.assertionFailure($0) }
    /// Where the IAB consent keys are read from.
    static var consentDefaults: UserDefaults = .standard
    /// Whether the app is active, for the clocks that count only time on screen.
    static var isApplicationActive: @MainActor () -> Bool = defaultIsApplicationActive
    /// The clock a bid's lifetime is measured on: seconds since an arbitrary point, monotonic, and still
    /// counting while the device sleeps (`CLOCK_MONOTONIC`; `systemUptime` stops in sleep, and a bid must
    /// expire in a locked pocket too). Never a `Date`: the user cannot set this one. Tests move it.
    nonisolated(unsafe) static var now: () -> TimeInterval = defaultNow

    static func reset() {
        session = .shared
        keyWindow = defaultKeyWindow
        schemeHandlers = [:]
        openURL = defaultOpenURL
        assertionFailure = { Swift.assertionFailure($0) }
        consentDefaults = .standard
        isApplicationActive = defaultIsApplicationActive
        now = defaultNow
    }

    private nonisolated static func defaultNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private static func defaultKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private static func defaultOpenURL(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in completion(opened) }
        }
    }

    private static func defaultIsApplicationActive() -> Bool {
        UIApplication.shared.applicationState == .active
    }
}
