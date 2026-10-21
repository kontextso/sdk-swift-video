import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// A player for tests: a view the test places in a window, and a playhead the test sets. `ads(for:)`
/// makes a `VideoAds` sized to the view that reads the playhead from here.
@MainActor
final class TestPlayer {
    let view: UIView
    var playhead: TimeInterval = 0

    init(size: CGSize = CGSize(width: 390, height: 220)) {
        view = UIView(frame: CGRect(origin: .zero, size: size))
    }

    func ads(for content: KontextVideo.Content, playerSize: CGSize? = nil) -> VideoAds {
        let ads = VideoAds(content: content, playerSize: playerSize ?? view.bounds.size)
        ads.playheadProvider = { [unowned self] in playhead }
        return ads
    }
}

/// Every delegate call, in order, as a readable line.
@MainActor
final class RecordingDelegate: VideoAdDelegate {
    private(set) var events: [String] = []
    private(set) var endReasons: [VideoAd.EndReason] = []
    private(set) var invalidations: [VideoAd.InvalidationReason] = []
    private(set) var failures: [VideoAdError] = []
    private(set) var clicks: [VideoAd.Click] = []
    private(set) var rewards: [VideoAd.Reward] = []

    func videoAd(_ ad: VideoAd, didInvalidate reason: VideoAd.InvalidationReason) {
        events.append("invalidate:\(reason)")
        invalidations.append(reason)
    }

    func videoAdDidRecordImpression(_ ad: VideoAd) { events.append("impression") }

    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {
        events.append("click:\(click.area)")
        clicks.append(click)
    }

    func videoAd(_ ad: VideoAd, didEarn reward: VideoAd.Reward) {
        events.append("reward:\(reward.label)")
        rewards.append(reward)
    }

    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {
        events.append("fail")
        failures.append(error)
    }

    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        events.append("end:\(reason)")
        endReasons.append(reason)
    }
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
    var configuration: KontextVideo.Configuration {
        KontextVideo.Configuration(publisherToken: "test-dev", logLevel: .none, adServerURL: server.baseURL)
    }

    init() {
        SDKHarness.reset()
        server.install()
        server.on("/v2/init", .json(Fixtures.initEnabled()))
        server.on("/events/", .empty())
        server.on("/v2/debug", .empty())
        KontextVideo.initRetryDelay = 10_000_000
        FrameBridge.loadTimeout = 30  // a CI runner can be slow; the warm-up below keeps real loads far under it
        Environment.isApplicationActive = { true }
        ViewabilityMeter.interval = 0.05
        Environment.keyWindow = { nil }
        Environment.consentDefaults = UserDefaults(suiteName: "KontextVideoSDKTests")!
        Environment.consentDefaults.removePersistentDomain(forName: "KontextVideoSDKTests")
    }

    /// Initializes the SDK and waits until `/init` answered. Also the moment WebKit is warmed up, so the
    /// first frame page of the process does not pay for spawning the web content process.
    func initialize() async -> KontextVideo.State {
        await WebKitWarmup.ensure()
        return await KontextVideo.shared.initialize(with: configuration)
    }

    /// Serves `ad` for the next ads request.
    func serve(_ ad: [String: Any]) {
        server.on("/v2/video/ads", .json(Fixtures.adsResponse(ad)))
    }

    static func reset() {
        KontextVideo.shared.resetForTesting()
        Environment.reset()
        StubServer.uninstall()
        KontextVideo.initRetryDelay = 2_000_000_000
        FrameBridge.loadTimeout = 10
        ViewabilityMeter.interval = 0.25
        DebugReporter.interval = 0.1
        DebugReporter.shared.isEnabled = false
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
