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
        KontextVideo.shared.initialize(with: Configuration(publisherToken: "example-dev", logLevel: .debug)) { state in
            status.state = "\(state)"
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(status: status)
        }
    }
}
