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
        case id, language, mediaRating, url, title, description, duration, episodeNumber, keywords, genre, series
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content.id, forKey: .id)
        try container.encode(content.language, forKey: .language)
        try container.encodeIfPresent(content.mediaRating?.rawValue, forKey: .mediaRating)
        try container.encodeIfPresent(content.url, forKey: .url)
        try container.encodeIfPresent(content.title, forKey: .title)
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

/// The `user` object: `id` always (the request is not built without one), empty optional strings left out: an
/// empty address or hash identifies nobody.
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
        try container.encode(user.id, forKey: .id)
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
        try container.encodeIfPresent(regulatory.gppSID, forKey: .gppSid)
        try container.encodeIfPresent(regulatory.usPrivacy, forKey: .usPrivacy)
    }
}

/// The request's rules for the app's content: what it sends, what the server would refuse.
extension KontextVideo.Content {
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

// COPPA: a child's request carries no identifier for advertising: no advertising id, no IDFV (Apple's Kids rules
// name device identifiers), no email or email hash. The user id and the install id stay: the server needs them, and
// its privacy decision keeps them from buyers. The rule is here, in one place; the request sends what these return.
extension Optional where Wrapped == KontextVideo.Regulatory {
    /// Whether the request is for a child: the publisher said COPPA applies (`coppa`).
    var isChild: Bool { self?.coppa == true }

    /// The user the request sends: for a child without the email and its hash (`withoutEmail`).
    func userToSend(_ user: KontextVideo.User) -> KontextVideo.User {
        isChild ? user.withoutEmail : user
    }

    /// A device identifier the request sends (the advertising id, the IDFV): none for a child.
    func deviceIdentifierToSend<Identifier>(_ identifier: Identifier?) -> Identifier? {
        isChild ? nil : identifier
    }
}

/// The request's rules for the app's user: a COPPA request's user, the fields left out.
extension KontextVideo.User {
    /// The user without the email and its hash, for a COPPA request: the id and the keywords stay.
    var withoutEmail: KontextVideo.User {
        KontextVideo.User(id: id, keywords: keywords)
    }

    /// The longest `id` the server takes, in characters as it counts them (UTF-16 code units).
    static let maxIdLength = 256

    /// Whether `id` is one the server takes: non-empty, at most `maxIdLength`. Without it no request is sent.
    var hasUsableId: Bool { !id.isEmpty && id.utf16.count <= Self.maxIdLength }

    /// Fields set to an empty string: an empty `id` stops every request and is an assertion; an empty email or
    /// hash is left out.
    var emptyFields: [String] {
        var fields = id.isEmpty ? ["id"] : []
        if email?.isEmpty == true { fields.append("email") }
        if emailHash?.isEmpty == true { fields.append("emailHash") }
        return fields
    }
}
