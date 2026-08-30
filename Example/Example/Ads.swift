import Foundation
import KontextVideoSDK

enum Ads {
    /// The example talks to the mock ad server
    /// (github.com/kontextso/sdk-video-mock-server) running on this Mac:
    /// `pnpm dev` there, then run the app in the simulator. For a physical
    /// device replace `localhost` with the Mac's LAN IP.
    private static let mockServerURL = URL(string: "http://localhost:5175")!

    @MainActor static let session = KontextVideo.createSession(VideoSessionOptions(
        publisherToken: "pub-example",
        userId: "user-example",
        adServerURL: mockServerURL,
        onEvent: { event in
            switch event {
            case .filled(let d): print("[Example] filled \(d.format) bid=\(d.bidId)")
            case .noFill(let d): print("[Example] noFill \(d.format) reason=\(d.reason ?? "-")")
            case .shown(let d): print("[Example] shown \(d.format) bid=\(d.bidId)")
            case .clicked(let d): print("[Example] clicked \(d.format) bid=\(d.bidId)")
            case .closed(let d): print("[Example] closed \(d.format) bid=\(d.bidId)")
            case .error(let e): print("[Example] error \(e.message)")
            }
        }
    ))
}
