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
            /// Required and non-empty; a series with an empty id is left out of the request.
            public let id: String
            public let title: String?
            public let description: String?
            /// Total number of episodes, at least 1; anything else is left out of the request.
            public let episodeCount: Int?

            public init(id: String, title: String? = nil, description: String? = nil, episodeCount: Int? = nil) {
                self.id = id
                self.title = title
                self.description = description
                self.episodeCount = episodeCount
            }

            private enum CodingKeys: String, CodingKey {
                case id, title, description, episodeCount
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encodeIfPresent(title, forKey: .title)
                try container.encodeIfPresent(description, forKey: .description)
                try container.encodeIfPresent(episodeCount.flatMap { $0 >= 1 ? $0 : nil }, forKey: .episodeCount)
            }
        }

        /// The publisher's own id of the video, any scheme. Required and non-empty: the server refuses a
        /// request without it, and a debug build stops at `VideoAds(content:)`.
        public let id: String
        /// BCP-47, for example "en" or "pt-BR". Required and non-empty, as `id`.
        public let language: String
        public let mediaRating: Rating?
        /// The episode's public page.
        public let url: URL?
        public let title: String?
        /// IAB Content Taxonomy 3.0 ids.
        public let categories: [String]?
        public let description: String?
        /// Seconds, sent as whole milliseconds. Left out of the request when it is not a length: NaN (as
        /// `AVPlayerItem.duration.seconds` before the item is ready, or live), infinite, or under 1 ms.
        public let duration: TimeInterval?
        /// At least 1; anything else is left out of the request.
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
            // A NaN (`AVPlayerItem.duration.seconds` before the item is ready, or live), infinite, negative or
            // absurd duration is left out rather than trapped on: it is contextual signal, not the ad.
            try container.encodeIfPresent(durationMs, forKey: .duration)
            try container.encodeIfPresent(episodeNumber.flatMap { $0 >= 1 ? $0 : nil }, forKey: .episodeNumber)
            try container.encodeIfPresent(keywords, forKey: .keywords)
            try container.encodeIfPresent(genre, forKey: .genre)
            try container.encodeIfPresent(series.flatMap { $0.id.isEmpty ? nil : $0 }, forKey: .series)
        }

        /// The duration as the request sends it: positive whole milliseconds, else nothing.
        var durationMs: Int? {
            duration.flatMap { seconds -> Int? in
                guard seconds.isFinite, seconds >= 0, let ms = Int(exactly: (seconds * 1000).rounded()), ms >= 1 else { return nil }
                return ms
            }
        }

        /// What the publisher passed that the server would refuse or the request leaves out, one phrase
        /// each; `VideoAds(content:)` reports them. Empty when the content is valid.
        var problems: [String] {
            var problems: [String] = []
            if id.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("id is empty") }
            if language.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("language is empty") }
            if let duration, durationMs == nil { problems.append("duration \(duration) s left out") }
            if let episodeNumber, episodeNumber < 1 { problems.append("episodeNumber \(episodeNumber) left out") }
            if let series, series.id.isEmpty { problems.append("series left out, its id is empty") }
            if let count = series?.episodeCount, count < 1 { problems.append("series.episodeCount \(count) left out") }
            return problems
        }
    }
}
