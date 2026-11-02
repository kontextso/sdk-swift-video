import Foundation

// What the app passes in, as the ads request sends it. The public types (`Content`, `User`, `Regulatory`,
// `AdFormat`) are plain values with no `Codable` conformance: the wire is the SDK's business, and a change
// to it must never be a change to the public API.

/// The `video` object of an ads request: `KontextVideo.Content` with absent fields left out, as are numbers
/// the server's schema would refuse (see `Content.duration` and `episodeNumber`); `duration` goes as
/// milliseconds.
struct ContentPayload: Encodable, Sendable {
    let content: KontextVideo.Content

    init(_ content: KontextVideo.Content) {
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case id, language, mediaRating, url, title, categories, description, duration, episodeNumber, keywords, genre, series
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content.id, forKey: .id)
        try container.encode(content.language, forKey: .language)
        try container.encodeIfPresent(content.mediaRating?.rawValue, forKey: .mediaRating)
        try container.encodeIfPresent(content.url, forKey: .url)
        try container.encodeIfPresent(content.title, forKey: .title)
        try container.encodeIfPresent(content.categories, forKey: .categories)
        try container.encodeIfPresent(content.description, forKey: .description)
        // A NaN (`AVPlayerItem.duration.seconds` before the item is ready, or live), infinite, negative or
        // absurd duration is left out rather than trapped on: it is contextual signal, not the ad.
        try container.encodeIfPresent(content.durationMs, forKey: .duration)
        try container.encodeIfPresent(content.episodeNumber.flatMap { $0 >= 1 ? $0 : nil }, forKey: .episodeNumber)
        try container.encodeIfPresent(content.keywords, forKey: .keywords)
        try container.encodeIfPresent(content.genre, forKey: .genre)
        try container.encodeIfPresent(content.series.flatMap { $0.id.isEmpty ? nil : SeriesPayload($0) }, forKey: .series)
    }
}

/// The `video.series` object: absent fields are left out, an `episodeCount` below 1 too.
struct SeriesPayload: Encodable, Sendable {
    let series: KontextVideo.Content.Series

    init(_ series: KontextVideo.Content.Series) {
        self.series = series
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, episodeCount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(series.id, forKey: .id)
        try container.encodeIfPresent(series.title, forKey: .title)
        try container.encodeIfPresent(series.description, forKey: .description)
        try container.encodeIfPresent(series.episodeCount.flatMap { $0 >= 1 ? $0 : nil }, forKey: .episodeCount)
    }
}

/// The `user` object: empty strings are left out, an empty id, address or hash identifies nobody.
struct UserPayload: Encodable, Sendable {
    let user: KontextVideo.User

    init(_ user: KontextVideo.User) {
        self.user = user
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, emailHash, keywords
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(user.id.flatMap { $0.isEmpty ? nil : $0 }, forKey: .id)
        try container.encodeIfPresent(user.email.flatMap { $0.isEmpty ? nil : $0 }, forKey: .email)
        try container.encodeIfPresent(user.emailHash.flatMap { $0.isEmpty ? nil : $0 }, forKey: .emailHash)
        try container.encodeIfPresent(user.keywords, forKey: .keywords)
    }
}

/// The `regulatory` object: the merged signals, `nil` fields left out.
struct RegulatoryPayload: Encodable, Sendable {
    let regulatory: KontextVideo.Regulatory

    init(_ regulatory: KontextVideo.Regulatory) {
        self.regulatory = regulatory
    }

    private enum CodingKeys: String, CodingKey {
        case gdpr, gdprConsent, coppa, gpp, gppSid, usPrivacy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(regulatory.gdpr, forKey: .gdpr)
        try container.encodeIfPresent(regulatory.gdprConsent, forKey: .gdprConsent)
        try container.encodeIfPresent(regulatory.coppa, forKey: .coppa)
        try container.encodeIfPresent(regulatory.gpp, forKey: .gpp)
        try container.encodeIfPresent(regulatory.gppSid, forKey: .gppSid)
        try container.encodeIfPresent(regulatory.usPrivacy, forKey: .usPrivacy)
    }
}

extension KeyedDecodingContainer {
    /// A format from its wire name. `AdFormat` is not `Decodable`: this keeps the call sites' spelling, and
    /// an unknown name fails as the raw-value decoding did.
    func decode(_ type: AdFormat.Type, forKey key: Key) throws -> AdFormat {
        let name = try decode(String.self, forKey: key)
        guard let format = AdFormat(rawValue: name) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "unknown format \(name)")
        }
        return format
    }
}
