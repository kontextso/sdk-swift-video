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
            case .loaded(let d):
                for r in d.results {
                    print("[Example] loaded \(r.format) \(r.ads.count)\(r.noFillReason.map { " (\($0))" } ?? "") \(r.ads.map { "\(String($0.id.prefix(8))) eCPM \($0.ecpm)" }.joined(separator: ", "))")
                }
            case .shown(let d): print("[Example] shown \(d.format) bid=\(d.adId)")
            case .clicked(let d): print("[Example] clicked \(d.format) bid=\(d.adId)")
            case .closed(let d): print("[Example] closed \(d.format) bid=\(d.adId)")
            case .completed(let d): print("[Example] completed \(d.format) bid=\(d.adId)")
            case .error(let e): print("[Example] error \(e.message)")
            }
        }
    ))
}
