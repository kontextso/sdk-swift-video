import AVFoundation
import KontextVideoSDK
import SwiftUI
import UIKit

/// The example's player: an AVPlayer in a view with an AVPlayerLayer. The SDK reads the playhead from
/// the player (`trackPlayhead(of:)`) and places overlay and pause ads in this view (`show(in:)`).
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The app side of the example: owns the player, the `VideoAds`, the loaded ads, and is the ads' delegate.
/// What it sees goes into `log`, which the screen shows.
@MainActor
final class Demo: ObservableObject {
    @Published var state = "initializing"
    @Published var log: [String] = []

    let contentPlayer = AVPlayer(url: URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4")!)
    let playerView = PlayerLayerView()
    private(set) var ads: VideoAds?
    private(set) var pauseAd: VideoAd?
    private(set) var overlayAd: VideoAd?
    private(set) var linear: VideoAd?

    init() {
        playerView.playerLayer.player = contentPlayer

        // The example talks to sdk-video-mock-server running on this Mac (`pnpm dev` there).
        // On a physical device replace localhost with the Mac's LAN address.
        let configuration = KontextVideo.Configuration(
            publisherToken: "example-debug",
            logLevel: .debug,
            adServerURL: URL(string: "http://localhost:5175")!
        )
        KontextVideo.shared.initialize(with: configuration) { [weak self] state in
            self?.state = "\(state)"
        }

        let content = KontextVideo.Content(
            id: "demo-episode-1",
            language: "en",
            title: "Episode 1",
            duration: 93,                // seconds
            episodeNumber: 1,
            genre: "romance",
            series: .init(id: "demo", title: "My Marionette Lover", episodeCount: 6)
        )
        // The player fills the screen in this example, so no playerSize; a smaller player would pass its size.
        let ads = VideoAds(content: content)
        self.ads = ads
        contentPlayer.play()
        ads.trackPlayhead(of: contentPlayer)   // the episode is playing in this player: the SDK reads its time
        ads.timingDelegate = self              // timed mode: the SDK says when a load is due; the app loads

        if CommandLine.arguments.contains("--demo") {
            runScriptedDemo()
        }
    }

    /// `--demo`: the pause and overlay flows without touching the screen, for automated runs.
    private func runScriptedDemo() {
        Task {
            await loadPauseAdAndWait()
            viewerPaused()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            viewerResumed()
            await loadOverlayAndWait()
            showOverlay()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            dismissOverlay()
            await loadLinearAndWait()
            showLinear()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Something outside the SDK dismisses the presentation: didEnd(.interrupted)
            Self.topViewController?.presentingViewController?.dismiss(animated: true)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // An ad loaded and dropped without being shown: released, placement free again
            await loadPauseAdAndWait()
            pauseAd = nil
            note("pause ad dropped without showing")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // An ad on screen when the VideoAds is destroyed: didEnd(.destroyed)
            await loadPauseAdAndWait()
            viewerPaused()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            destroy()
        }
    }

    private func loadLinearAndWait() async {
        do {
            let ad = try await ads!.linearPlacement("linear").load(LinearOptions(timing: .midroll))
            ad.delegate = self
            linear = ad
            note("linear ad \(ad.id.prefix(8)) ready, \(ad.price.value) \(ad.price.currency) cpm, \(Int(ad.duration ?? 0)) s")
        } catch {
            note("linear ad load: \(error)")
        }
    }

    func loadLinear() {
        Task { await loadLinearAndWait() }
    }

    /// The linear ad is presented by the SDK from the key window's top view controller (`show()`); the
    /// content pauses here and resumes in didEnd.
    func showLinear() {
        guard let ad = linear else { return }
        contentPlayer.pause()
        do {
            try ad.show()
        } catch {
            contentPlayer.play()                 // never started: undo here, no delegate call follows
            note("linear ad show: \(error)")
        }
    }

    private static var topViewController: UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private func loadPauseAdAndWait() async {
        do {
            let ad = try await ads!.pausePlacement("pause").load(PauseOptions(positions: [.top, .bottom]))
            ad.delegate = self
            pauseAd = ad
            note("pause ad \(ad.id.prefix(8)) ready, \(ad.price.value) \(ad.price.currency) cpm")
        } catch {
            note("pause load: \(error)")
        }
    }

    private func loadOverlayAndWait() async {
        do {
            let ad = try await ads!.overlayPlacement("overlay").load(OverlayOptions(positions: [.bottom]))
            ad.delegate = self
            overlayAd = ad
            note("overlay \(ad.id.prefix(8)) ready, \(ad.price.value) \(ad.price.currency) cpm")
        } catch {
            note("overlay load: \(error)")
        }
    }

    func loadPauseAd() {
        Task { await loadPauseAdAndWait() }
    }

    func loadOverlay() {
        Task { await loadOverlayAndWait() }
    }

    /// The pause idiom: show if ready, else load for next time.
    func viewerPaused() {
        contentPlayer.pause()
        guard let ad = pauseAd, ad.isReady else {
            note("no pause ad ready, loading one")
            loadPauseAd()
            return
        }
        do {
            try ad.show(in: playerView)
        } catch {
            note("pause show: \(error)")
        }
    }

    func viewerResumed() {
        pauseAd?.dismiss()
        contentPlayer.play()
    }

    func showOverlay() {
        guard let ad = overlayAd, ad.isReady else { return }   // a windowed overlay may already be up (videoAdDidReachWindow)
        do {
            try ad.show(in: playerView)
        } catch {
            note("overlay show: \(error)")
        }
    }

    func dismissOverlay() {
        overlayAd?.dismiss()
    }

    func destroy() {
        ads?.destroy()
        note("destroyed")
    }

    private func note(_ line: String) {
        log.append(line)
    }
}

extension Demo: VideoAdDelegate {
    func videoAd(_ ad: VideoAd, didInvalidate reason: VideoAd.InvalidationReason) {
        note("\(ad.format) \(ad.id.prefix(8)) invalidated: \(reason)")
    }

    /// Timed mode: the ad's window opened. An overlay goes into the player view now; a linear ad pauses
    /// the content and presents. Not shown by the window's end: didInvalidate(.windowPassed).
    func videoAdDidReachWindow(_ ad: VideoAd) {
        note("\(ad.format) \(ad.id.prefix(8)) window reached")
        do {
            switch ad.format {
            case .overlay: try ad.show(in: playerView)
            case .linear: contentPlayer.pause(); try ad.show()
            case .pause: break
            }
        } catch {
            note("\(ad.format) show at window: \(error)")
        }
    }

    func videoAdDidRecordImpression(_ ad: VideoAd) {
        note("\(ad.format) \(ad.id.prefix(8)) impression")
    }

    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {
        note("\(ad.format) \(ad.id.prefix(8)) click (\(click.area)) \(click.url.host ?? "")")
    }

    func videoAd(_ ad: VideoAd, didEarn reward: VideoAd.Reward) {
        note("\(ad.format) \(ad.id.prefix(8)) reward \(reward.amount) \(reward.label)")
    }

    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {
        note("\(ad.format) \(ad.id.prefix(8)) failed: \(error)")
    }

    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        note("\(ad.format) \(ad.id.prefix(8)) ended: \(reason)")
        if ad.format == .linear { contentPlayer.play() }      // every way it ends lands here
        if ad === pauseAd { pauseAd = nil }
        if ad === overlayAd { overlayAd = nil }
        if ad === linear { linear = nil }
    }
}

@main
struct ExampleApp: App {
    @StateObject private var demo = Demo()

    var body: some Scene {
        WindowGroup {
            ContentView(demo: demo)
        }
    }
}

extension Demo: VideoAdsTimingDelegate {
    /// The SDK never loads by itself: it says when a load makes sense (the server's nextRequestAt came, the
    /// viewer seeked, a pending ad was discarded) and the app decides. The demo logs it; a real app loads.
    func videoAds(_ ads: VideoAds, didRequestLoadOf placementId: String, reason: VideoAds.LoadReason) {
        note("load due for \(placementId): \(reason)")
    }
}
