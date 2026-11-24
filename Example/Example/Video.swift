import KontextVideoSDK
import SwiftUI

/// One video per situation in a short-drama app. Its page says where in the app the player is; the ad
/// server's configuration decides which formats it offers there. The app asks for the format it shows.
struct Video: Identifiable {
    let id: String
    let title: String
    let format: AdFormat
    /// Sent with every ads request of this video: `VideoAds(content:page:)`.
    let page: String
    let cover: [Color]
    let url: URL

    /// What happens once the video plays.
    let caption: String

    static let all: [Video] = [
        Video(id: "demo-overlay", title: "Revenge of the Heiress", format: .overlay,
              page: "freeEpisodes", cover: [.orange, .red], url: clip,
              caption: "An overlay after 3 s of playing; pausing ends it"),
        Video(id: "demo-overlay-top", title: "Midnight Vows", format: .overlay,
              page: "freeEpisodesTop", cover: [.yellow, .orange], url: clip,
              caption: "An overlay after 3 s of playing, placed as its page's configuration says (the top, for example); pausing ends it"),
        Video(id: "demo-linear", title: "The CEO's Secret", format: .linear,
              page: "unlock", cover: [.pink, .purple], url: clip,
              caption: "A linear ad after 3 s of playing"),
        Video(id: "demo-pause", title: "Moonlit Contract", format: .pause,
              page: "firstEpisode", cover: [.indigo, .blue], url: clip,
              caption: "Tap to pause: a pause ad shows, a card or the whole player as its page's configuration says; tap again, or the ad's Resume, to play on"),
    ]

    /// Its ad shows while the content is paused.
    var isPause: Bool { format == .pause }

    /// A bundled portrait clip; every video plays it.
    private static let clip = Bundle.main.url(forResource: "sample-episode", withExtension: "mp4")!
}
