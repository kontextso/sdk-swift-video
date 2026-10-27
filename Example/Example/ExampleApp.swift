import KontextVideoSDK
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        // The ad server's demo routes answer any token; put your own publisher token here.
        let configuration = KontextVideo.Configuration(publisherToken: "example-debug", logLevel: .debug)
        KontextVideo.shared.initialize(with: configuration)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
