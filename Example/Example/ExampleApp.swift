import KontextVideoSDK
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        KontextVideo.shared.initialize(with: Configuration(publisherToken: "example-dev"))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
