import Foundation

/// The video the ads are for. Everything beyond `id`, `language` and `mediaRating` is
/// contextual signal: send what you have.
public struct Video: Encodable, Sendable, Equatable {
    /// The publisher's own id of the video, any scheme.
    public let id: String
    /// BCP-47, for example "en" or "pt-BR".
    public let language: String
    public let mediaRating: MediaRating
    /// The episode's public page.
    public let url: URL?
    public let title: String?
    /// IAB Content Taxonomy 3.0 ids.
    public let categories: [String]?
    public let description: String?
    /// Milliseconds.
    public let duration: Int?
    public let episodeNumber: Int?
    public let keywords: [String]?
    /// For example "romance".
    public let genre: String?
    public let series: Series?

    public init(
        id: String,
        language: String,
        mediaRating: MediaRating = .safe,
        url: URL? = nil,
        title: String? = nil,
        categories: [String]? = nil,
        description: String? = nil,
        duration: Int? = nil,
        episodeNumber: Int? = nil,
        keywords: [String]? = nil,
        genre: String? = nil,
        series: Series? = nil
    ) {
        self.id = id
        self.language = language
        self.mediaRating = mediaRating
        self.url = url
        self.title = title
        self.categories = categories
        self.description = description
        self.duration = duration
        self.episodeNumber = episodeNumber
        self.keywords = keywords
        self.genre = genre
        self.series = series
    }
}

/// A simplified rating: `explicit` content gets no ads that require safe content.
public enum MediaRating: String, Encodable, Sendable {
    case safe
    case explicit
}

/// The series an episode belongs to.
public struct Series: Encodable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let description: String?
    /// Total number of episodes.
    public let episodeCount: Int?

    public init(id: String, title: String? = nil, description: String? = nil, episodeCount: Int? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.episodeCount = episodeCount
    }
}
