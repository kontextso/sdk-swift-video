import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// A player for tests: a view the test places in a window, and a playhead the test sets. `ads(for:)`
/// makes a `VideoAds` that reads the playhead from here.
@MainActor
final class TestPlayer {
    let view: UIView
    var playhead: TimeInterval = 0

    init(size: CGSize = CGSize(width: 390, height: 220)) {
        view = UIView(frame: CGRect(origin: .zero, size: size))
    }

    func ads(for content: KontextVideo.Content) -> VideoAds {
        let ads = VideoAds(content: content)
        ads.playheadProvider = { [unowned self] in playhead }
        return ads
    }
}

/// Every delegate call, in order, as a readable line.
@MainActor
final class RecordingDelegate: VideoAdDelegate {
    private(set) var events: [String] = []
    private(set) var endReasons: [VideoAd.EndReason] = []
    private(set) var failures: [VideoAdError] = []
    private(set) var clicks: [VideoAd.Click] = []
    /// What the app does inside the impression callback; a test that dismisses from there sets it.
    var onImpression: ((VideoAd) -> Void)?

    func videoAdDidRecordImpression(_ ad: VideoAd) {
        events.append("impression")
        onImpression?(ad)
    }

    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {
        events.append("click:\(click.area)")
        clicks.append(click)
    }

    /// What the app does inside `didFail`; a test that destroys from there sets it.
    var onFail: ((VideoAd) -> Void)?

    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {
        events.append("fail")
        failures.append(error)
        onFail?(ad)
    }

    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        events.append("end:\(reason)")
        endReasons.append(reason)
    }
}

/// Records every SKAdNetwork call the SDK makes, in order; `init` names the advertised app.
@MainActor
final class RecordingSKAdNetwork: SKAdNetworkManaging {
    private(set) var calls: [String] = []
    /// What each call does before it returns; a test that wants one slow or failing sets it.
    var onInit: (@MainActor () async throws -> Void)?
    var onStart: (@MainActor () async throws -> Void)?
    var onEnd: (@MainActor () async throws -> Void)?
    var onDispose: (@MainActor () async throws -> Void)?

    func initImpression(_ skan: Skan) async throws {
        calls.append("init \(skan.itunesItem)")
        try await onInit?()
    }

    func startImpression() async throws {
        calls.append("start")
        try await onStart?()
    }

    func endImpression() async throws {
        calls.append("end")
        try await onEnd?()
    }

    func dispose() async throws {
        calls.append("dispose")
        try await onDispose?()
    }
}

/// Records the App Store sheets the SDK asked for; `result` is what each presentation answers.
@MainActor
final class RecordingStoreProduct: StoreProductManaging {
    private(set) var presented: [Skan] = []
    var result: Result<Bool, Error> = .success(true)
    /// What the presentation does before it answers; a test that holds the sheet loading sets it.
    var onPresent: (@MainActor () async -> Void)?

    func present(_ skan: Skan) async throws -> Bool {
        presented.append(skan)
        await onPresent?()
        return try result.get()
    }
}

struct TestFailure: Error {}

/// Where an overlay or pause ad's creative sits in `player`, in its coordinates: the host covers the
/// whole player and holds the creative at its place.
@MainActor
func adFrame(in player: UIView) -> CGRect? {
    guard let host = player.subviews.last as? AdHostView else { return nil }
    return host.convert(host.content.frame, to: player)
}

/// A window the tests can put views into. Made key and visible so WebKit treats the views as on screen.
@MainActor
final class TestWindow {
    let window: UIWindow
    let root = UIViewController()

    init(size: CGSize = CGSize(width: 390, height: 844)) {
        // Transitions in a headless window never finish with animations on.
        UIView.setAnimationsEnabled(false)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
    }

    func add(_ view: UIView) {
        root.view.addSubview(view)
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// One visible window for the whole run where the bridge parks loading pages. Never made key, so it does
/// not take key status from the windows the tests present in.
@MainActor
enum ParkingWindow {
    static let window: UIWindow = {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: .zero)
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .normal - 1
        window.isHidden = false
        return window
    }()
}

/// Moves the SDK's clock forward by `seconds` from now: what expiry tests use instead of waiting, so a
/// slow runner cannot change the outcome. `SDKHarness.reset()` puts the real clock back.
@MainActor
func advanceClock(by seconds: TimeInterval) {
    let previous = Environment.now
    Environment.now = { previous() + seconds }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(_ timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
func sleepMs(_ ms: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

/// Everything a test needs around the shared instance: a stub server, a reset before and after.
@MainActor
struct SDKHarness {
    let server = StubServer()
    let player = TestPlayer()
    let skAdNetwork = RecordingSKAdNetwork()
    let storeProduct = RecordingStoreProduct()
    var configuration: KontextVideo.Configuration {
        KontextVideo.Configuration(publisherToken: "test-dev", logLevel: .none, adServerURL: server.baseURL)
    }

    init() {
        SDKHarness.reset()
        server.install()
        server.on("/v2/config", .json(Fixtures.initEnabled()))
        server.on("/events/", .empty())
        server.on("/v2/debug", .empty())
        server.on("/v2/error", .empty())
        KontextVideo.configRetryDelay = 0.01
        FrameBridge.loadTimeout = 30  // a CI runner can be slow; the warm-up below keeps real loads far under it
        Environment.isApplicationActive = { true }
        ViewabilityMeter.interval = 0.05
        Environment.keyWindow = { nil }
        // Pages load in a window, as in an app: WebKit deprioritizes the web process of a WebView outside
        // any window, and on a loaded CI runner a page then missed its 30 s load limit.
        Environment.parkingWindow = { ParkingWindow.window }
        Environment.consentDefaults = UserDefaults(suiteName: "KontextVideoSDKTests")!
        Environment.consentDefaults.removePersistentDomain(forName: "KontextVideoSDKTests")
        Environment.skAdNetwork = skAdNetwork
        Environment.storeProduct = storeProduct
    }

    /// Initializes the SDK and waits until `/config` answered. Also the moment WebKit is warmed up, so the
    /// first frame page of the process does not pay for spawning the web content process.
    func initialize() async -> KontextVideo.State {
        await WebKitWarmup.ensure()
        return await KontextVideo.shared.initialize(with: configuration)
    }

    /// Answers every ads request with `ad` for its own format and a no-fill for the others.
    func serve(_ ad: [String: Any], delay: TimeInterval = 0, gate: StubServer.Gate? = nil) {
        server.on("/v2/video/ads") { _ in
            var response = StubServer.Response.json(Fixtures.adsResponse(ad))
            response.delay = delay
            response.gate = gate
            return response
        }
    }

    /// Answers every ads request with one entry per format: `entries` by format name, a no-fill for the rest.
    func serve(formats entries: [String: [String: Any]], delay: TimeInterval = 0, gate: StubServer.Gate? = nil) {
        server.on("/v2/video/ads") { _ in
            var response = StubServer.Response.json(Fixtures.adsResponse(formats: entries))
            response.delay = delay
            response.gate = gate
            return response
        }
    }

    /// The `/video/ads` requests the SDK sent, in order.
    var adsRequests: [StubServer.Recorded] { server.requests(to: "/v2/video/ads") }

    static func reset() {
        KontextVideo.shared.resetForTesting()
        Environment.reset()
        StubServer.uninstall()
        KontextVideo.configRetryDelay = 2
        FrameBridge.loadTimeout = 10
        ViewabilityMeter.interval = 0.25
        // The runner never completes a modal transition: a linear ad's didEnd comes from the fallback.
        VideoAd.dismissalTimeout = 0.05
        DebugReporter.interval = 0.1
        DebugReporter.shared.isEnabled = false
        ErrorReporter.interval = 0.01
        ErrorReporter.retryDelay = 30
        ErrorReporter.maxRetryDelay = 300
        SKAdNetworkImpression.queue = nil
    }
}

/// The first frame page of a process is slow: WebKit spawns a web content process for the bridge's
/// non-persistent data store, and on a cold CI runner that took longer than the page-load timeout.
/// Loading one real frame page once, through the real bridge, before the first test that needs a page,
/// moves that cost out of every test.
@MainActor
enum WebKitWarmup {
    private static var done = false

    static func ensure() async {
        guard !done else { return }
        done = true
        // A page server of its own, so no suite sees the warm-up page in what its server served.
        let previous = Environment.schemeHandlers
        FramePageServer().install()
        let bridge = FrameBridge(adId: "img-warmup", url: URL(string: "\(Fixtures.frameOrigin)/frame/img-warmup")!, isVideo: false)
        var loaded = false
        bridge.onEvent = { if case .loaded = $0 { loaded = true } }
        let timeout = FrameBridge.loadTimeout
        FrameBridge.loadTimeout = 60
        bridge.load()
        _ = await waitUntil(60) { loaded }
        bridge.hide()
        FrameBridge.loadTimeout = timeout
        Environment.schemeHandlers = previous
    }
}
