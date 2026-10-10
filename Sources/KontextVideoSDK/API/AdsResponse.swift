/// The answer to `POST /video/ads`.
enum AdsResponse: Decodable, Sendable {
    /// `nextRequestAt`: milliseconds in content time; do not ask for this format again before the playhead reaches it.
    case ad(AdPayload, nextRequestAt: Int?)
    /// `retryAfter`: milliseconds, only with `temporaryError`.
    case noFill(reason: String, retryAfter: Int?, nextRequestAt: Int?)
    /// The server switched the SDK off.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case ad
        case noFillReason
        case retryAfter
        case nextRequestAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Bool.self, forKey: .enabled) else {
            self = .disabled(reason: try container.decodeIfPresent(String.self, forKey: .disabledReason) ?? "unknown")
            return
        }
        let nextRequestAt = try container.decodeIfPresent(Int.self, forKey: .nextRequestAt)
        if let ad = try container.decodeIfPresent(AdPayload.self, forKey: .ad) {
            self = .ad(ad, nextRequestAt: nextRequestAt)
        } else {
            self = .noFill(
                reason: try container.decodeIfPresent(String.self, forKey: .noFillReason) ?? "unknown",
                retryAfter: try container.decodeIfPresent(Int.self, forKey: .retryAfter),
                nextRequestAt: nextRequestAt
            )
        }
    }
}
