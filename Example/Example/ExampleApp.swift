import KontextVideoSDK
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        // The ad server's demo routes answer any token; put your own publisher token here.
        // The SDK asks for App Tracking Transparency right before its first ads request; the IDFA raises fill.
        let configuration = KontextVideo.Configuration(
            publisherToken: "example-debug",
            requestTrackingAuthorization: true,
            logLevel: .debug
        )
        KontextVideo.shared.initialize(with: configuration)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
