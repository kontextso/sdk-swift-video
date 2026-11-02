import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// A linear ad's full-screen controller where UIKit does not do what the SDK asked: a dismissal that never
/// finishes. The ad is presented for real from a controller in a window of its own; the runner never
/// completes a transition, so its presenter answers the dismissal itself.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdLinearTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameBridge.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    /// Keeps every `VideoAds` a test created alive for the test's duration: the ad holds its owner weakly.
    private let owners = Owners()

    final class Owners {
        var all: [VideoAds] = []
    }

    /// A presenter that records the dismissals asked of it; with `completes` off it never calls back, as when
    /// UIKit drops a dismissal's completion.
    final class Presenter: UIViewController {
        var dismissals = 0
        var completes = true
        override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
            dismissals += 1
            if completes { completion?() }
        }
    }

    /// A loaded ad, owned by `ads` (a new `VideoAds` when nil), with a recording delegate.
    private func makeAd(_ payload: [String: Any], in ads: VideoAds? = nil) async throws -> (VideoAd, RecordingDelegate, VideoAds) {
        _ = await harness.initialize()
        let ads = ads ?? harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        send(ad, "ad.loaded")
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        return (ad, delegate, ads)
    }

    private func send(_ ad: VideoAd, _ type: String, _ extra: [String: Any] = [:]) {
        var body: [String: Any] = ["adId": ad.id, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        ad.bridge.receive(body, from: sender)
    }

    /// A linear ad presented from `presenter` in a window of its own; the controller's view is put in the
    /// window directly, as the runner never completes the transition, so the meter sees the ad.
    private func presentLinear(_ ad: VideoAd, from presenter: Presenter) async throws -> (LinearViewController, UIWindow) {
        let window = UIWindow(windowScene: try #require(self.window.window.windowScene))
        window.frame = self.window.window.frame
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        try ad.show(from: presenter)
        let controller = try #require(ad.linearController)
        #expect(await waitUntil { presenter.presentedViewController === controller })
        window.addSubview(controller.view)
        ad.presented()
        return (controller, window)
    }

    /// Every report that reached the server, in order.
    private func reports() -> [[String: Any]] {
        harness.server.requests(to: "/v2/error").flatMap { ($0.body?["errors"] as? [[String: Any]]) ?? [] }
    }

    // MARK: A dismissal that never finishes

    @Test func aDismissalUIKitNeverFinishesIsReportedAndDidEndComesOnceAfterTheWatchdog() async throws {
        VideoAd.dismissalTimeout = 0.05
        defer { VideoAd.dismissalTimeout = 1; Logger.level = .warning }
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportErrors: true)))
        let presenter = Presenter()
        presenter.completes = false
        let (ad, delegate, ads) = try await makeAd(Fixtures.linearAd(id: "i40"))
        Logger.level = .error
        var errors: [String] = []
        Logger.sink = { level, message in if level == .error { errors.append(message) } }
        let (_, window) = try await presentLinear(ad, from: presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.skip", ["playhead": 1000])
        #expect(presenter.dismissals == 1, "the SDK asked UIKit to dismiss")
        #expect(ad.hasEnded && delegate.endReasons.isEmpty, "didEnd waits for the dismissal")
        // The screen stays taken while the dismissal is pending: another ad cannot show over it.
        let (next, _, _) = try await makeAd(Fixtures.linearAd(id: "i41"), in: ads)
        do { try next.show(from: self.window.root) } catch VideoAdError.anotherAdShowing {} catch { Issue.record("expected anotherAdShowing, got \(error)") }
        #expect(next.isReady && !next.wasShown)
        // The controller is still in a window: the watchdog waits for its cap, then delivers didEnd anyway.
        #expect(await waitUntil { delegate.endReasons == [.skipped] }, "didEnd after the watchdog")
        #expect(await waitUntil { !reports().isEmpty })
        let report = try #require(reports().first)
        #expect(report["code"] as? String == "ad.dismissal_timed_out" && report["stage"] as? String == "presentation")
        #expect(report["adId"] as? String == "i40" && report["sessionId"] as? String == ads.sessionId)
        #expect(report["recovery"] as? String == "did_end_delivered")
        #expect(errors.count == 1 && errors.first?.contains("dismissal did not finish") == true, "logged once: \(errors)")
        await sleepMs(200)
        #expect(delegate.endReasons == [.skipped], "once")
        #expect(reports().count == 1, "reported once")
        // The slot is free: the next ad shows.
        #expect(KontextVideo.shared.adOnScreen == nil)
        try next.show(from: self.window.root)
        #expect(next.wasShown && KontextVideo.shared.adOnScreen === next)
    }
}
}
