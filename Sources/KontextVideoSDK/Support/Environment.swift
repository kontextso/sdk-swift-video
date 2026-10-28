import AppTrackingTransparency
import Foundation
import UIKit
import WebKit

/// The SDK's seams: what tests replace and production never touches. Every value has its production
/// default; `reset()` restores them all.
@MainActor
enum Environment {
    /// The session every request and beacon goes through: the SDK's own, never the app's shared one.
    static var session: URLSession = defaultSession

    /// The SDK's session policy, in one place. Ephemeral and without cookies or a cache: nothing the
    /// server sends is stored, and the app's own cookie store and cache are not touched. `deadline` bounds
    /// a whole request: `URLRequest.timeoutInterval` is an idle timeout only, so a server that trickles
    /// bytes would otherwise hold a request (and every `format()` call that joined it) for as long as it
    /// likes; the session default is seven days. Tests build theirs here too, adding the stub protocol.
    static func makeSession(deadline: TimeInterval = APIClient.defaultTimeout, configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = deadline
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configure(configuration)
        return URLSession(configuration: configuration)
    }

    private static let defaultSession = makeSession()
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
    /// App Tracking Transparency: the status now, and the dialog. Tests answer without the OS.
    static var trackingAuthorizationStatus: @MainActor () -> ATTrackingManager.AuthorizationStatus = { ATTrackingManager.trackingAuthorizationStatus }
    static var requestTrackingAuthorization: @MainActor () async -> ATTrackingManager.AuthorizationStatus = { await ATTrackingManager.requestTrackingAuthorization() }
    /// Registers and ends the SKAdNetwork impression of an app-install ad on screen.
    static var skAdNetwork: any SKAdNetworkManaging = KontextKitSKAdNetwork()
    /// Presents the App Store product sheet an app-install ad's click opens.
    static var storeProduct: any StoreProductManaging = KontextKitStoreProduct()
    /// The clock an ad's lifetime is measured on: seconds since an arbitrary point, monotonic, and still
    /// counting while the device sleeps (`CLOCK_MONOTONIC`; `systemUptime` stops in sleep, and an ad must
    /// expire in a locked pocket too). Never a `Date`: the user cannot set this one. Tests move it.
    nonisolated(unsafe) static var now: () -> TimeInterval = defaultNow

    // Called by the tests, which the analyzer does not see.
    // swiftlint:disable:next unused_declaration
    static func reset() {
        session = defaultSession
        keyWindow = defaultKeyWindow
        schemeHandlers = [:]
        openURL = defaultOpenURL
        assertionFailure = { Swift.assertionFailure($0) }
        consentDefaults = .standard
        isApplicationActive = defaultIsApplicationActive
        trackingAuthorizationStatus = { ATTrackingManager.trackingAuthorizationStatus }
        requestTrackingAuthorization = { await ATTrackingManager.requestTrackingAuthorization() }
        skAdNetwork = KontextKitSKAdNetwork()
        storeProduct = KontextKitStoreProduct()
        now = defaultNow
    }

    private nonisolated static func defaultNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// The key window of the scene receiving events, else of a foreground scene that is not (an iPhone
    /// while a system alert is up, the ATT dialog included). Active first: `connectedScenes` is a set, and
    /// an iPad with two foreground windows must not get whichever comes first. A background scene's
    /// window cannot present anything the viewer sees.
    private static func defaultKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = { (state: UIScene.ActivationState) in
            scenes.filter { $0.activationState == state }.flatMap(\.windows).first { $0.isKeyWindow }
        }
        return keyWindow(.foregroundActive) ?? keyWindow(.foregroundInactive)
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
