import KontextVideoSDK
import SwiftUI

/// What the SDK reported back, for the screen to show.
final class SDKStatus: ObservableObject {
    @Published var state = "initializing"
    /// The ads of the episode the example "plays": created right after initialize, so the loads
    /// wait for /init.
    var ads: VideoAds?
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
        status.ads = VideoAds(content: content, player: player)
        status.ads?.start()          // the episode is "playing": requests carry the playhead
        status.ads?.overlayPlacement("overlay").load(OverlayOptions(positions: [.bottom]))
        status.ads?.pausePlacement("pause").load(PauseOptions(positions: [.top]))
        status.ads?.interstitialPlacement("interstitial").load(InterstitialOptions(timing: .preroll))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(status: status)
        }
    }
}
