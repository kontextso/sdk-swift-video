/// The answer to `POST /video/ads`. `nextRequestAt` (timed mode) is on the wire but not read: the SDK
/// has no timed mode yet, every ad is shown at a moment the app picks.
enum AdsResponse: Decodable, Sendable {
    /// Stands in for a `noFillReason` or `disabledReason` the server left out or sent malformed; the
    /// answer itself is still understood.
    static let unknownReason = "unknown"

    case ad(AdPayload)
    /// `retryAfter`: milliseconds, only with `temporaryError`.
    case noFill(reason: String, retryAfter: Int?)
    /// The server switched the SDK off.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case ad
        case noFillReason
        case retryAfter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Bool.self, forKey: .enabled) else {
            self = .disabled(reason: (try? container.decodeIfPresent(String.self, forKey: .disabledReason)) ?? Self.unknownReason)
            return
        }
        if let ad = try container.decodeIfPresent(AdPayload.self, forKey: .ad) {
            self = .ad(ad)
        } else {
            self = .noFill(
                reason: (try? container.decodeIfPresent(String.self, forKey: .noFillReason)) ?? Self.unknownReason,
                retryAfter: try container.decodeIfPresent(Int.self, forKey: .retryAfter)
            )
        }
    }
}
