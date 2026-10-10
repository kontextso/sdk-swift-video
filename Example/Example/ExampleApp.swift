import KontextVideoSDK
import SwiftUI

/// What the SDK reported back, for the screen to show.
final class SDKStatus: ObservableObject {
    @Published var state = "initializing"
    /// The ads of the episode the example "plays": created right after initialize, so the loads
    /// wait for /init.
    var ads: VideoAds?
    /// One line per load, as it finished.
    @Published var loads: [String] = []
    /// The ads the app holds; dropping one frees its placement.
    var loadedAds: [VideoAd] = []
}

/// Stands in for the app's player: the SDK reads the view the content plays in and the playhead.
/// A real app conforms its player controller (or a wrapper around AVPlayer).
@MainActor
final class DemoPlayer: KontextVideoPlayer {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    var playhead: TimeInterval = 0
}

@main
struct ExampleApp: App {
    private let status = SDKStatus()
    private let player = DemoPlayer()

    init() {
        let status = self.status
        // The example talks to sdk-video-mock-server running on this Mac (`pnpm dev` there).
        // On a physical device replace localhost with the Mac's LAN address.
        let configuration = KontextVideo.Configuration(
            publisherToken: "example-dev",
            logLevel: .debug,
            adServerURL: URL(string: "http://localhost:5175")!
        )
        KontextVideo.shared.initialize(with: configuration) { state in
            status.state = "\(state)"
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
        status.ads = ads

        // Each load returns the ad or throws; the app owns the ad it gets.
        Task {
            let load = { label, work in await Self.load(label, into: status, work) }
            await load("overlay") { try await ads.overlayPlacement("overlay").load(OverlayOptions(positions: [.bottom])) }
            await load("pause") { try await ads.pausePlacement("pause").load(PauseOptions(positions: [.top])) }
            await load("interstitial") { try await ads.interstitialPlacement("interstitial").load(InterstitialOptions(timing: .preroll)) }
            // Two ways a load fails that are the app's fault, shown on purpose:
            await load("pause again") { try await ads.pausePlacement("pause").load() }          // .placementBusy
            await load("nope") { try await ads.overlayPlacement("nope").load() }                 // .invalidPlacement
        }
    }

    /// Runs one load and records what came back.
    private static func load(_ label: String, into status: SDKStatus, _ work: () async throws -> VideoAd) async {
        do {
            let ad = try await work()
            status.loadedAds.append(ad)
            status.loads.append("\(label): \(ad.format) \(ad.id.prefix(8)), \(ad.price.value) \(ad.price.currency) cpm, ready: \(ad.isReady)")
        } catch {
            status.loads.append("\(label): \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(status: status)
        }
    }
}
