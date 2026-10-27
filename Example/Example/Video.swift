import KontextVideoSDK
import SwiftUI

/// One video per ad format: opening it shows that format and nothing else.
struct Video: Identifiable {
    let id: String
    let title: String
    let format: AdFormat
    let cover: [Color]
    let url: URL

    /// What happens once the video plays.
    var caption: String {
        switch format {
        case .linear: return "A linear ad after 3 s"
        case .overlay: return "An overlay after 3 s"
        case .pause: return "Tap to pause: a pause ad shows, tap again to resume"
        }
    }

    static let all: [Video] = [
        Video(id: "demo-linear", title: "The CEO's Secret", format: .linear, cover: [.pink, .purple], url: clip),
        Video(id: "demo-overlay", title: "Revenge of the Heiress", format: .overlay, cover: [.orange, .red], url: clip),
        Video(id: "demo-pause", title: "Moonlit Contract", format: .pause, cover: [.indigo, .blue], url: clip),
    ]

    /// A bundled portrait clip; every video plays it.
    private static let clip = Bundle.main.url(forResource: "sample-episode", withExtension: "mp4")!
}
