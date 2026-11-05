import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// A linear ad's full-screen controller when UIKit does not simply present and dismiss it: a dismissal that
/// never finishes, a screen presented over the ad. The ad is presented for real from a controller in a
/// window of its own; the runner never completes a transition, so its presenter answers the dismissal itself.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdLinearTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
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
    private func presentLinear(_ ad: VideoAd, from presenter: Presenter) async throws -> (LinearAdViewController, UIWindow) {
        let window = UIWindow(windowScene: try #require(self.window.window.windowScene))
        window.frame = self.window.window.frame
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        try ad.show(from: presenter)
        let controller = try #require(ad.linearController)
        #expect(await waitUntil { presenter.presentedViewController === controller })
        window.addSubview(controller.view)
        ad.reachedScreen()
        return (controller, window)
    }

    /// Every report that reached the server, in order.
    private func reports() -> [[String: Any]] {
        harness.server.requests(to: "/v2/error").flatMap { ($0.body?["errors"] as? [[String: Any]]) ?? [] }
    }

    // MARK: A dismissal that never finishes

    @Test func aDismissalUIKitNeverFinishesIsReportedAndDidEndComesOnceAfterTheWatchdog() async throws {
        LinearScreen.dismissalTimeout = 0.05
        defer { LinearScreen.dismissalTimeout = 1; Logger.level = .warning }
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

    // MARK: A screen over the ad

    @Test func aFullScreenCoverOverALinearAdPausesItsMeasurementAndTheAdGoesOnOnceTheCoverGoes() async throws {
        let presenter = Presenter()
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i42"))
        var exposures: [Double] = []
        ad.bridge.onSend = { type, payload in if type == "ad.exposure", let value = payload["exposedPercentage"] as? Double { exposures.append(value) } }
        let (controller, window) = try await presentLinear(ad, from: presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        send(ad, "video.start", ["playhead": 0])
        #expect(await waitUntil { exposures.last.map { $0 > 50 } == true }, "on screen: \(exposures)")
        // The app presents its own screen, or an install click the App Store sheet, full screen over the ad. The
        // runner refuses a presentation over a controller whose own never finished, so the check is told; what
        // UIKit then does to the ad's controller is done by hand: viewDidDisappear, its view out of the window.
        var covered = true
        Environment.isCovered = { $0 === controller && covered }
        controller.viewDisappeared(isBeingDismissed: false, isMovingFromParent: false, hasPresenter: true)
        controller.view.removeFromSuperview()
        exposures.removeAll()
        // Three seconds of ticks under the cover, past the two a video needs to be viewable.
        for _ in 0..<30 {
            advanceClock(by: 0.1)
            ad.meter?.tick()
        }
        #expect(!exposures.isEmpty && exposures.allSatisfy { $0 == 0 }, "the page hears exposure 0: \(exposures)")
        #expect(ad.meter?.verdict == nil, "covered time is not counted as visible")
        #expect(delegate.endReasons.isEmpty && !ad.hasEnded, "not interrupted: the view is out of the window only under the cover")
        #expect(presenter.dismissals == 0 && ad.linearController === controller && KontextVideo.shared.adOnScreen === ad)
        // The cover goes: the view is back, the page hears the exposure, and the dwell starts again.
        covered = false
        window.addSubview(controller.view)
        #expect(await waitUntil { exposures.last.map { $0 > 50 } == true }, "exposed again: \(exposures)")
        for _ in 0..<25 {
            advanceClock(by: 0.1)
            ad.meter?.tick()
        }
        #expect(ad.meter?.verdict == .viewable)
        #expect(await waitUntil { self.harness.server.beacons.contains { $0.event == "viewable" } })
        // A genuine end later: dismissed once, one didEnd.
        send(ad, "video.skip", ["playhead": 3000])
        #expect(await waitUntil { delegate.endReasons == [.skipped] })
        await sleepMs(100)
        #expect(delegate.endReasons == [.skipped] && presenter.dismissals == 1)
    }

    @Test func aSheetOverALinearAdReadsAsExposure0AndTheAdGoesOnOnceItGoes() async throws {
        let presenter = Presenter()
        let (ad, delegate, _) = try await makeAd(Fixtures.linearAd(id: "i43"))
        var exposures: [Double] = []
        ad.bridge.onSend = { type, payload in if type == "ad.exposure", let value = payload["exposedPercentage"] as? Double { exposures.append(value) } }
        let (controller, window) = try await presentLinear(ad, from: presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        send(ad, "video.start", ["playhead": 0])
        #expect(await waitUntil { exposures.last.map { $0 > 50 } == true }, "on screen: \(exposures)")
        // A sheet (the App Store product page after a click) leaves the ad's view in its window.
        var covered = true
        Environment.isCovered = { $0 === controller && covered }
        exposures.removeAll()
        for _ in 0..<30 {
            advanceClock(by: 0.1)
            ad.meter?.tick()
        }
        #expect(controller.view.window != nil, "still in the window under a sheet")
        #expect(!exposures.isEmpty && exposures.allSatisfy { $0 == 0 }, "the page hears exposure 0 and pauses: \(exposures)")
        #expect(ad.meter?.verdict == nil, "time under the sheet is not counted as visible")
        #expect(delegate.endReasons.isEmpty && !ad.hasEnded)
        // The sheet goes: exposed again, and the dwell starts over.
        covered = false
        for _ in 0..<25 {
            advanceClock(by: 0.1)
            ad.meter?.tick()
        }
        #expect(exposures.last.map { $0 > 50 } == true, "exposed again: \(exposures)")
        #expect(ad.meter?.verdict == .viewable)
    }
}
}
