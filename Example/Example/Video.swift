import KontextVideoSDK
import SwiftUI

/// One video per situation in a short-drama app. Its labels say where the viewer is (`stage`) and how the
/// player looks (`layout`); the ad server's rules turn them into the one format it offers there. The app
/// still asks for the format it shows: the others come back as no fill.
struct Video: Identifiable {
    let id: String
    let title: String
    let format: AdFormat
    /// Sent with every ads request of this video: `VideoAds(content:labels:)`.
    let labels: [String: String]
    let cover: [Color]
    let url: URL

    /// What happens once the video plays.
    let caption: String

    /// The labels as the card shows them, in a fixed order.
    var labelText: String {
        labels.sorted { $0.key > $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · ")
    }

    static let all: [Video] = [
        Video(id: "demo-pause", title: "Moonlit Contract", format: .pause,
              labels: ["stage": "first_episode", "layout": "inline"], cover: [.indigo, .blue], url: clip,
              caption: "First episode: only when the viewer pauses, a pause card. Tap to pause, tap again to resume"),
        Video(id: "demo-pause-fullscreen", title: "The Heir's Return", format: .pause,
              labels: ["stage": "first_episode", "layout": "fullscreen"], cover: [.teal, .green], url: clip,
              caption: "First episode, full-screen player: a full-screen pause ad. Tap to pause, tap again to resume"),
        Video(id: "demo-overlay", title: "Revenge of the Heiress", format: .overlay,
              labels: ["stage": "free_episodes"], cover: [.orange, .red], url: clip,
              caption: "Free episodes: an overlay after 3 s, the story keeps playing"),
        Video(id: "demo-linear", title: "The CEO's Secret", format: .linear,
              labels: ["stage": "unlock"], cover: [.pink, .purple], url: clip,
              caption: "A locked episode, unlocked by an ad: a linear ad after 3 s"),
    ]

    /// A bundled portrait clip; every video plays it.
    private static let clip = Bundle.main.url(forResource: "sample-episode", withExtension: "mp4")!
}
