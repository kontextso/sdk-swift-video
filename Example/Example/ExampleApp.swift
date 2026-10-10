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
            duration: 93_000,
            episodeNumber: 1,
            genre: "romance",
            series: .init(id: "demo", title: "My Marionette Lover", episodeCount: 6)
        )
        let player = KontextVideo.Player(width: 393, height: 852, fullscreen: true)
        status.ads = VideoAds(content: content, player: player)
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
