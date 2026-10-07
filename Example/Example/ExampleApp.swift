import KontextVideoSDK
import SwiftUI

/// What the SDK reported back, for the screen to show.
final class SDKStatus: ObservableObject {
    @Published var state = "initializing"
    /// The ads of the episode the example "plays": created right after initialize, so the loads
    /// wait for /init.
    var ads: VideoAds?
}

@main
struct ExampleApp: App {
    private let status = SDKStatus()

    init() {
        let status = self.status
        // The example talks to sdk-video-mock-server running on this Mac (`pnpm dev` there).
        // On a physical device replace localhost with the Mac's LAN address.
        let configuration = Configuration(
            publisherToken: "example-dev",
            logLevel: .debug,
            adServerUrl: URL(string: "http://localhost:5175")!
        )
        KontextVideo.shared.initialize(with: configuration) { state in
            status.state = "\(state)"
        }

        let video = Video(
            id: "demo-episode-1",
            language: "en",
            title: "Episode 1",
            duration: 93_000,
            episodeNumber: 1,
            genre: "romance",
            series: Series(id: "demo", title: "My Marionette Lover", episodeCount: 6)
        )
        let player = Player(width: 393, height: 852, fullscreen: true)
        status.ads = KontextVideo.shared.createVideoAds(for: video, player: player)
        status.ads?.overlay.load(OverlayOptions(positions: [.bottom]))
        status.ads?.pause.load(PauseOptions(positions: [.top]))
        status.ads?.interstitial.load(InterstitialOptions(timing: .preroll))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(status: status)
        }
    }
}
