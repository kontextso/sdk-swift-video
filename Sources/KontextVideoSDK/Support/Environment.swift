import Foundation
import UIKit
import WebKit

/// The SDK's seams: what tests replace and production never touches. Every value has its production
/// default; `reset()` restores them all.
@MainActor
enum Environment {
    /// The session every request and beacon goes through.
    static var session: URLSession = .shared
    /// Where a loading WebView is parked so WebKit buffers its video.
    static var keyWindow: () -> UIWindow? = {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
    /// Custom URL schemes the frame WebView can load, so a test serves a page from inside the process.
    static var schemeHandlers: [String: WKURLSchemeHandler] = [:]
    /// Opens a URL the page asked for; the completion says whether it could.
    static var openURL: (URL, @escaping (Bool) -> Void) -> Void = { url, completion in
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }
    /// A programmer error: stops a debug build. Tests record it instead.
    static var assertionFailure: (String) -> Void = { message in
        Swift.assertionFailure(message)
    }
    /// Where the IAB consent keys are read from.
    static var consentDefaults: UserDefaults = .standard

    static func reset() {
        session = .shared
        keyWindow = {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
        }
        schemeHandlers = [:]
        openURL = { url, completion in UIApplication.shared.open(url, options: [:], completionHandler: completion) }
        assertionFailure = { Swift.assertionFailure($0) }
        consentDefaults = .standard
    }
}
