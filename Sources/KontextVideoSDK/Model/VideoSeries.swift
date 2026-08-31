import Foundation

/// Metadata of the series the video belongs to — for publishers whose
/// context lives at the series level (short drama: the episode has no
/// synopsis of its own). Everything is optional except the id; send what
/// you have.
public struct VideoSeries: Sendable, Encodable {
    /// Publisher's series id.
    public let id: String
    public let title: String?
    /// Synopsis — the main contextual signal when episodes carry none.
    public let description: String?
    public let keywords: [String]?
    /// Content rating / brand-safety flag, e.g. `"18+"`. Constrains which
    /// campaigns may serve.
    public let contentRating: String?
    /// Languages the series is available in (BCP-47 / ISO 639 codes).
    public let languages: [String]?
    public let episodeCount: Int?

    public init(
        id: String,
        title: String? = nil,
        description: String? = nil,
        keywords: [String]? = nil,
        contentRating: String? = nil,
        languages: [String]? = nil,
        episodeCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.keywords = keywords
        self.contentRating = contentRating
        self.languages = languages
        self.episodeCount = episodeCount
    }
}
