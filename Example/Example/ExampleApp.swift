import KontextVideoSDK
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        // The example talks to sdk-video-mock-server running on this Mac (`pnpm dev` there); on a physical
        // device replace localhost with the Mac's LAN address. With your own publisher token, drop `adServerURL`.
        let configuration = KontextVideo.Configuration(
            publisherToken: "example-debug",
            logLevel: .debug,
            adServerURL: URL(string: "http://localhost:5175")!
        )
        KontextVideo.shared.initialize(with: configuration)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
