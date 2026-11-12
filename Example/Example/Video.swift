import KontextVideoSDK
import SwiftUI

/// One video per situation in a short-drama app. Its section says where in the app the player is; the ad
/// server's configuration decides which formats it offers there. The app asks for the format it shows.
struct Video: Identifiable {
    let id: String
    let title: String
    let format: AdFormat
    /// Sent with every ads request of this video: `VideoAds(content:section:)`.
    let section: String
    let cover: [Color]
    let url: URL

    /// What happens once the video plays.
    let caption: String

    static let all: [Video] = [
        Video(id: "demo-overlay", title: "Revenge of the Heiress", format: .overlay,
              section: "free_episodes", cover: [.orange, .red], url: clip,
              caption: "An overlay after 3 s of playing; pausing ends it"),
        Video(id: "demo-overlay-top", title: "Midnight Vows", format: .overlay,
              section: "free_episodes_top", cover: [.yellow, .orange], url: clip,
              caption: "An overlay after 3 s of playing, placed as its section's configuration says (the top, for example); pausing ends it"),
        Video(id: "demo-linear", title: "The CEO's Secret", format: .linear,
              section: "unlock", cover: [.pink, .purple], url: clip,
              caption: "A linear ad after 3 s of playing"),
        Video(id: "demo-pause-fullscreen", title: "The Heir's Return", format: .pauseFullscreen,
              section: "first_episode", cover: [.teal, .green], url: clip,
              caption: "Tap to pause: a full-screen pause ad shows, its Resume plays on"),
        Video(id: "demo-pause", title: "Moonlit Contract", format: .pause,
              section: "first_episode", cover: [.indigo, .blue], url: clip,
              caption: "Tap to pause: a pause ad shows, tap again to resume"),
    ]

    /// Its ad shows while the content is paused.
    var isPause: Bool { format == .pause || format == .pauseFullscreen }

    /// A bundled portrait clip; every video plays it.
    private static let clip = Bundle.main.url(forResource: "sample-episode", withExtension: "mp4")!
}
