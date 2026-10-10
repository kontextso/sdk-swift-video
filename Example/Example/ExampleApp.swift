import KontextVideoSDK
import SwiftUI
import UIKit

/// Stands in for the app's player: the SDK reads the view the content plays in and the playhead.
/// A real app conforms its player controller (or a wrapper around AVPlayer).
@MainActor
final class DemoPlayer: KontextVideoPlayer {
    let view = UIView()
    var playhead: TimeInterval = 0
}

/// The app side of the example: owns the player, the `VideoAds`, the loaded ads, and is the ads' delegate.
/// What it sees goes into `log`, which the screen shows.
@MainActor
final class Demo: ObservableObject {
    @Published var state = "initializing"
    @Published var log: [String] = []

    let player = DemoPlayer()
    private(set) var ads: VideoAds?
    private(set) var pauseAd: VideoAd?
    private(set) var overlayAd: VideoAd?
    private(set) var interstitial: VideoAd?

    init() {
        // The example talks to sdk-video-mock-server running on this Mac (`pnpm dev` there).
        // On a physical device replace localhost with the Mac's LAN address.
        let configuration = KontextVideo.Configuration(
            publisherToken: "example-dev",
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
        let ads = VideoAds(content: content, player: player)
        ads.start()                  // the episode is "playing": requests carry the playhead
        self.ads = ads

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
            await loadInterstitialAndWait()
            showInterstitial()
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

    private func loadInterstitialAndWait() async {
        do {
            let ad = try await ads!.interstitialPlacement("interstitial").load(InterstitialOptions(timing: .midroll))
            ad.delegate = self
            interstitial = ad
            note("interstitial \(ad.id.prefix(8)) ready, \(ad.price.value) \(ad.price.currency) cpm, \(Int(ad.duration ?? 0)) s")
        } catch {
            note("interstitial load: \(error)")
        }
    }

    func loadInterstitial() {
        Task { await loadInterstitialAndWait() }
    }

    /// The interstitial is presented by the SDK over everything; the content would pause here and resume in didEnd.
    func showInterstitial() {
        guard let ad = interstitial, let presenter = Self.topViewController else { return }
        do {
            try ad.show(from: presenter)
        } catch {
            note("interstitial show: \(error)")
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
        guard let ad = pauseAd, ad.isReady else {
            note("no pause ad ready, loading one")
            loadPauseAd()
            return
        }
        do {
            try ad.show()
        } catch {
            note("pause show: \(error)")
        }
    }

    func viewerResumed() {
        pauseAd?.dismiss()
    }

    func showOverlay() {
        guard let ad = overlayAd else { return }
        do {
            try ad.show()
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

    func videoAdDidShow(_ ad: VideoAd) {
        note("\(ad.format) \(ad.id.prefix(8)) shown")
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
        note("\(ad.format) \(ad.id.prefix(8)) ended: \(reason)")   // the content would resume here
        if ad === pauseAd { pauseAd = nil }
        if ad === overlayAd { overlayAd = nil }
        if ad === interstitial { interstitial = nil }
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
