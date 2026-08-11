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

extension Story {
    /// Sample stories backed by public test videos (Google's gtv-videos-bucket).
    static let samples: [Story] = [
        Story(
            id: "ceo-secret",
            title: "The CEO's Secret",
            genre: "Romance",
            coverGradient: [.pink, .purple],
            episodes: [
                .sample(story: "ceo-secret", number: 1, title: "The Interview", file: "ForBiggerBlazes"),
                .sample(story: "ceo-secret", number: 2, title: "Late Night at the Office", file: "ForBiggerEscapes"),
                .sample(story: "ceo-secret", number: 3, title: "The Gala", file: "ForBiggerFun"),
            ]
        ),
        Story(
            id: "revenge-heiress",
            title: "Revenge of the Heiress",
            genre: "Drama",
            coverGradient: [.orange, .red],
            episodes: [
                .sample(story: "revenge-heiress", number: 1, title: "Disinherited", file: "ForBiggerJoyrides"),
                .sample(story: "revenge-heiress", number: 2, title: "The Return", file: "ForBiggerMeltdowns"),
                .sample(story: "revenge-heiress", number: 3, title: "Checkmate", file: "ForBiggerBlazes"),
            ]
        ),
        Story(
            id: "moonlit-contract",
            title: "Moonlit Contract",
            genre: "Fantasy",
            coverGradient: [.indigo, .blue],
            episodes: [
                .sample(story: "moonlit-contract", number: 1, title: "The Pact", file: "ForBiggerEscapes"),
                .sample(story: "moonlit-contract", number: 2, title: "Blood Moon", file: "ForBiggerFun"),
                .sample(story: "moonlit-contract", number: 3, title: "Broken Vows", file: "ForBiggerJoyrides"),
            ]
        ),
        Story(
            id: "second-chance",
            title: "Second Chance Love",
            genre: "Romance",
            coverGradient: [.teal, .green],
            episodes: [
                .sample(story: "second-chance", number: 1, title: "Ten Years Later", file: "ForBiggerMeltdowns"),
                .sample(story: "second-chance", number: 2, title: "The Reunion", file: "ForBiggerBlazes"),
                .sample(story: "second-chance", number: 3, title: "One More Try", file: "ForBiggerEscapes"),
            ]
        ),
    ]
}

private extension Episode {
    static func sample(story: String, number: Int, title: String, file: String) -> Episode {
        Episode(
            id: "\(story)-ep\(number)",
            number: number,
            title: title,
            videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/\(file).mp4")!
        )
    }
}
