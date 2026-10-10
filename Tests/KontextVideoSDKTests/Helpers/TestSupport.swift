import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// A player for tests: a view the test places in a window, and a playhead the test sets.
@MainActor
final class TestPlayer: KontextVideoPlayer {
    let view: UIView
    var playhead: TimeInterval = 0

    init(size: CGSize = CGSize(width: 390, height: 220)) {
        view = UIView(frame: CGRect(origin: .zero, size: size))
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

    func videoAdDidShow(_ ad: VideoAd) { events.append("show") }
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
        Init.retryDelay = 10_000_000
        FrameBridge.loadTimeout = 3   // the first WebView of a process takes over a second to come up
        VideoAd.videoStartBackstop = 1
        ViewabilityMeter.interval = 0.05
        Environment.keyWindow = { nil }
        Environment.consentDefaults = UserDefaults(suiteName: "KontextVideoSDKTests")!
        Environment.consentDefaults.removePersistentDomain(forName: "KontextVideoSDKTests")
    }

    /// Initializes the SDK and waits until `/init` answered.
    func initialize() async -> KontextVideo.State {
        await KontextVideo.shared.initialize(with: configuration)
    }

    /// Serves `ad` for the next ads request.
    func serve(_ ad: [String: Any], nextRequestAt: Int? = nil) {
        server.on("/v2/video/ads", .json(Fixtures.adsResponse(ad, nextRequestAt: nextRequestAt)))
    }

    static func reset() {
        KontextVideo.shared.resetForTesting()
        Environment.reset()
        StubServer.uninstall()
        Init.retryDelay = 2_000_000_000
        KontextVideo.initRetryInterval = 300
        FrameBridge.loadTimeout = 10
        VideoAd.videoStartBackstop = 5
        ViewabilityMeter.interval = 0.25
        DebugReporter.interval = 1
        DebugReporter.shared.isEnabled = false
    }
}
