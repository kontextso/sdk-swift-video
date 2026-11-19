import KontextVideoSDK
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        // Put your publisher token here: Kontext gives you a `{publisher}-dev` one for development.
        // The SDK asks for App Tracking Transparency right before its first ads request; the IDFA raises fill.
        let configuration = KontextVideo.Configuration(
            publisherToken: "YOUR_PUBLISHER_TOKEN",
            requestTrackingAuthorization: true,
            logLevel: .debug
        )
        KontextVideo.shared.initialize(with: configuration)
        // The viewer, required before the first ads request: a guest id this install keeps until the viewer signs
        // in, then the account id.
        KontextVideo.shared.user = KontextVideo.User(id: Self.guestId)
    }

    /// A random id made on the first launch and kept in the app's defaults.
    private static var guestId: String {
        if let id = UserDefaults.standard.string(forKey: "guestId") { return id }
        let id = "guest-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: "guestId")
        return id
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
