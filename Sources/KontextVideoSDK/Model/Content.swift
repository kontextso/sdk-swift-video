import Foundation

extension KontextVideo {
    /// The publisher's video the ads are for, "content" in ad-industry terms (VAST
    /// `[CONTENTPLAYHEAD]`). Everything beyond `id` and `language` is contextual signal: send what you have.
    /// Times are seconds in Swift and milliseconds on the wire. A plain value: the SDK encodes it itself.
    public struct Content: Sendable, Equatable, Hashable {
        /// A simplified rating: `explicit` content gets no ads that require safe content. Leave it unset
        /// when you do not know: OpenRTB's media rating has no "unknown" value, so the SDK never defaults it.
        public enum Rating: String, Sendable, Hashable {
            /// Suitable for every advertiser.
            case safe
            /// Mature content: only ads that accept it.
            case explicit
        }

        /// The series an episode belongs to.
        public struct Series: Sendable, Equatable, Hashable {
            /// Required and non-empty; a series with an empty id is left out of the request.
            public let id: String
            /// The series' public name.
            public let title: String?
            /// A short synopsis of the series.
            public let description: String?
            /// Total number of episodes, at least 1; anything else is left out of the request.
            public let episodeCount: Int?

            /// Only `id` is required; the rest is contextual signal.
            public init(id: String, title: String? = nil, description: String? = nil, episodeCount: Int? = nil) {
                self.id = id
                self.title = title
                self.description = description
                self.episodeCount = episodeCount
            }
        }

        /// The publisher's own id of the video, any scheme. Required and non-empty: the server refuses a
        /// request without it, and a debug build stops at `VideoAds(content:)`.
        public let id: String
        /// BCP-47, for example "en" or "pt-BR". Required and non-empty, as `id`.
        public let language: String
        /// Whether the video suits every advertiser; `nil` when you do not know.
        public let mediaRating: Rating?
        /// The episode's public page.
        public let url: URL?
        /// The episode's public name.
        public let title: String?
        /// IAB Content Taxonomy 3.0 ids.
        public let categories: [String]?
        /// A short synopsis of the episode.
        public let description: String?
        /// Seconds, rounded to the nearest whole millisecond. Left out of the request when negative,
        /// non-finite (NaN is what `AVPlayerItem.duration.seconds` gives before the item is ready, or for
        /// live), beyond the representable range, or rounded to less than 1 ms.
        public let duration: TimeInterval?
        /// At least 1; anything else is left out of the request.
        public let episodeNumber: Int?
        /// Words that describe the video, in the publisher's own terms.
        public let keywords: [String]?
        /// For example "romance".
        public let genre: String?
        /// The series the episode belongs to, when it is one.
        public let series: Series?

        /// Only `id` and `language` are required; the rest is contextual signal, send what you have.
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

        /// The duration as the request sends it: positive whole milliseconds, else nothing.
        var durationMs: Int? {
            duration.flatMap { seconds -> Int? in
                guard seconds.isFinite, seconds >= 0, let ms = Int(exactly: (seconds * 1000).rounded()), ms >= 1 else { return nil }
                return ms
            }
        }

        /// Required fields the publisher left empty: every request fails at the server. The rule is the
        /// schema's, a non-empty string; `" "` passes, as it does there.
        var missingRequired: [String] {
            [id.isEmpty ? "id is empty" : nil, language.isEmpty ? "language is empty" : nil].compactMap { $0 }
        }

        /// Optional metadata the request leaves out because the server would refuse it, one phrase each.
        var leftOut: [String] {
            var problems: [String] = []
            if let duration, durationMs == nil { problems.append("duration \(duration) s left out") }
            if let episodeNumber, episodeNumber < 1 { problems.append("episodeNumber \(episodeNumber) left out") }
            if let series, series.id.isEmpty { problems.append("series left out, its id is empty") }
            if let count = series?.episodeCount, count < 1 { problems.append("series.episodeCount \(count) left out") }
            return problems
        }
    }
}
