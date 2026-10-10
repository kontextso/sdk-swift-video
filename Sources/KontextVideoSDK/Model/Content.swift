import Foundation

extension KontextVideo {
    /// The publisher's video the ads are for, "content" in ad-industry terms (VAST `[CONTENTPLAYHEAD]`,
    /// IMA `contentTitle`). Everything beyond `id` and `language` is contextual signal: send what you have.
    /// Times are seconds in Swift and milliseconds on the wire.
    public struct Content: Encodable, Sendable, Equatable {
        /// A simplified rating: `explicit` content gets no ads that require safe content. Leave it unset
        /// when you do not know: OpenRTB's media rating has no "unknown" value, so the SDK never defaults it.
        public enum Rating: String, Encodable, Sendable {
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

        /// The publisher's own id of the video, any scheme.
        public let id: String
        /// BCP-47, for example "en" or "pt-BR".
        public let language: String
        public let mediaRating: Rating?
        /// The episode's public page.
        public let url: URL?
        public let title: String?
        /// IAB Content Taxonomy 3.0 ids.
        public let categories: [String]?
        public let description: String?
        /// Seconds.
        public let duration: TimeInterval?
        public let episodeNumber: Int?
        public let keywords: [String]?
        /// For example "romance".
        public let genre: String?
        public let series: Series?

        public init(
            id: String,
            language: String,
            mediaRating: Rating? = nil,
            url: URL? = nil,
            title: String? = nil,
            categories: [String]? = nil,
            description: String? = nil,
            duration: TimeInterval? = nil,
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

        private enum CodingKeys: String, CodingKey {
            case id, language, mediaRating, url, title, categories, description, duration, episodeNumber, keywords, genre, series
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(language, forKey: .language)
            try container.encodeIfPresent(mediaRating, forKey: .mediaRating)
            try container.encodeIfPresent(url, forKey: .url)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(categories, forKey: .categories)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(duration.map { Int(($0 * 1000).rounded()) }, forKey: .duration)
            try container.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
            try container.encodeIfPresent(keywords, forKey: .keywords)
            try container.encodeIfPresent(genre, forKey: .genre)
            try container.encodeIfPresent(series, forKey: .series)
        }
    }
}
