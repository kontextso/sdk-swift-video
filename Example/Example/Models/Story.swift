import SwiftUI

struct Story: Identifiable, Hashable {
    let id: String
    let title: String
    let genre: String
    let coverGradient: [Color]
    let episodes: [Episode]
}

struct Episode: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let videoURL: URL
}

/// Bundled portrait (9:16) sample clip — every episode plays this same video.
/// Source: Mixkit free stock footage (ocean waves), re-used under the Mixkit license.
private let sampleVideoURL = Bundle.main.url(forResource: "sample-episode", withExtension: "mp4")!

extension Story {
    static let samples: [Story] = [
        Story(
            id: "ceo-secret",
            title: "The CEO's Secret",
            genre: "Romance",
            coverGradient: [.pink, .purple],
            episodes: .samples(story: "ceo-secret", titles: [
                "The Interview", "Late Night at the Office", "The Gala",
            ])
        ),
        Story(
            id: "revenge-heiress",
            title: "Revenge of the Heiress",
            genre: "Drama",
            coverGradient: [.orange, .red],
            episodes: .samples(story: "revenge-heiress", titles: [
                "Disinherited", "The Return", "Checkmate",
            ])
        ),
        Story(
            id: "moonlit-contract",
            title: "Moonlit Contract",
            genre: "Fantasy",
            coverGradient: [.indigo, .blue],
            episodes: .samples(story: "moonlit-contract", titles: [
                "The Pact", "Blood Moon", "Broken Vows",
            ])
        ),
        Story(
            id: "second-chance",
            title: "Second Chance Love",
            genre: "Romance",
            coverGradient: [.teal, .green],
            episodes: .samples(story: "second-chance", titles: [
                "Ten Years Later", "The Reunion", "One More Try",
            ])
        ),
    ]
}

private extension [Episode] {
    static func samples(story: String, titles: [String]) -> [Episode] {
        titles.enumerated().map { index, title in
            Episode(
                id: "\(story)-ep\(index + 1)",
                number: index + 1,
                title: title,
                videoURL: sampleVideoURL
            )
        }
    }
}
