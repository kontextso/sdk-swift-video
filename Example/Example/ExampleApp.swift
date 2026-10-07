import KontextVideoSDK
import SwiftUI

/// What the SDK reported back, for the screen to show.
final class SDKStatus: ObservableObject {
    @Published var state = "initializing"
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView(status: status)
        }
    }
}
