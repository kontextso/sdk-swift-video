import AdSupport
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
    /// Where `show()` finds its presenter, and what the request reports as the player when nothing else says.
    static var keyWindow: @MainActor () -> UIWindow? = defaultKeyWindow
    /// Where a loading WebView is parked so WebKit runs its page and buffers its video: the key window.
    /// Separate from `keyWindow` only so the tests can give pages a window without changing what the
    /// requests report or where a linear ad is presented.
    static var parkingWindow: @MainActor () -> UIWindow? = { keyWindow() }
    /// Custom URL schemes the frame WebView can load, so a test serves a page from inside the process.
    static var schemeHandlers: [String: WKURLSchemeHandler] = [:]
    /// Opens a URL the page asked for; the completion says whether it could.
    static var openURL: @MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void = defaultOpenURL
    /// A programmer error: stops a debug build. Tests record it instead.
    static var assertionFailure: (String) -> Void = { Swift.assertionFailure($0) }
    /// Where the IAB consent keys are read from.
    static var consentDefaults: UserDefaults = .standard
    /// Whether a controller has another presented over it: a full-screen cover takes its view out of the
    /// window, which is not the ad's end.
    static var isCovered: @MainActor (UIViewController) -> Bool = { $0.presentedViewController != nil }
    /// Whether the app is active, for the clocks that count only time on screen.
    static var isApplicationActive: @MainActor () -> Bool = defaultIsApplicationActive
    /// Whether the scene of a given window is active, for the viewability of an ad in it.
    static var isWindowActive: @MainActor (UIWindow) -> Bool = defaultIsWindowActive
    /// App Tracking Transparency: the status now, and the dialog. Tests answer without the OS.
    static var trackingAuthorizationStatus: @MainActor () -> ATTrackingManager.AuthorizationStatus = { ATTrackingManager.trackingAuthorizationStatus }
    static var requestTrackingAuthorization: @MainActor () async -> ATTrackingManager.AuthorizationStatus = { await ATTrackingManager.requestTrackingAuthorization() }
    /// The device's advertising identifier, all zeros unless ATT is authorized. Tests set a real one.
    static var advertisingIdentifier: @MainActor () -> UUID = { ASIdentifierManager.shared().advertisingIdentifier }
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
        parkingWindow = { keyWindow() }
        schemeHandlers = [:]
        openURL = defaultOpenURL
        assertionFailure = { Swift.assertionFailure($0) }
        consentDefaults = .standard
        isApplicationActive = defaultIsApplicationActive
        isWindowActive = defaultIsWindowActive
        isCovered = { $0.presentedViewController != nil }
        trackingAuthorizationStatus = { ATTrackingManager.trackingAuthorizationStatus }
        advertisingIdentifier = { ASIdentifierManager.shared().advertisingIdentifier }
        requestTrackingAuthorization = { await ATTrackingManager.requestTrackingAuthorization() }
        skAdNetwork = KontextKitSKAdNetwork()
        storeProduct = KontextKitStoreProduct()
        now = defaultNow
    }

    private nonisolated static func defaultNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private static func defaultKeyWindow() -> UIWindow? {
        let delegateWindow = UIApplication.shared.delegate?.window.flatMap { $0 }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.map { (state: $0.activationState, windows: $0.windows) }
        return keyWindow(scenes: scenes, delegateWindow: delegateWindow)
    }

    /// The key window of the scene receiving events, else of a foreground scene that is not (an iPhone
    /// while a system alert is up, the ATT dialog included). Active first: `connectedScenes` is a set.
    /// Best effort with two active scenes (iPad): either may be the player's, and `show(from:)` or
    /// `show(in:)` names the right one. A background scene's window cannot present anything the viewer
    /// sees. An app without scenes keeps its window on the app delegate, so with no window scene at all
    /// that one is used.
    /// The scenes come as plain values (state and windows), so the choice can be tested: a test cannot make
    /// window scenes in a chosen state. `isKey` is the window's `isKeyWindow`, a parameter for the same reason.
    static func keyWindow(
        scenes: [(state: UIScene.ActivationState, windows: [UIWindow])],
        delegateWindow: UIWindow?,
        isKey: (UIWindow) -> Bool = { $0.isKeyWindow }
    ) -> UIWindow? {
        guard !scenes.isEmpty else { return delegateWindow }
        for state in [UIScene.ActivationState.foregroundActive, .foregroundInactive] {
            if let window = scenes.filter({ $0.state == state }).flatMap(\.windows).first(where: isKey) { return window }
        }
        return nil
    }

    /// Whether an ad in `window` can be seen: the app is active and so is the window's own scene. On an
    /// iPad one window can go to the background while another stays active, which the app-wide state alone
    /// does not show. A window without a scene (an app without scenes) follows the app.
    private static func defaultIsWindowActive(_ window: UIWindow) -> Bool {
        isWindowActive(appActive: isApplicationActive(), sceneState: window.windowScene?.activationState)
    }

    /// The rule behind `isWindowActive`, over plain values; `sceneState` is `nil` for a window without a scene.
    static func isWindowActive(appActive: Bool, sceneState: UIScene.ActivationState?) -> Bool {
        appActive && (sceneState.map { $0 == .foregroundActive } ?? true)
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
