/// The answer to `POST /video/ads`: one entry per format (the SDK always asks for all of them), each with
/// its ads or its no-fill reason; or the kill switch. `nextRequestAt` (timed mode) is on the wire but
/// not read: the SDK has no timed mode yet, every ad is shown at a moment the app picks.
enum AdsResponse: Decodable, Sendable {
    /// Stands in for a `disabledReason` the server left out or sent malformed; the answer itself is
    /// still understood. (`NoFillReason.unknown` is the same for a no-fill.)
    static let unknownReason = "unknown"

    /// One per format. `ads` is a sequence, the first to be shown first; today a filled entry
    /// carries one. Decoded strictly on `format` and `ads` (they decide the answer), leniently on the reason.
    struct FormatResult: Decodable, Sendable {
        let format: AdFormat
        let ads: [AdPayload]
        /// Set exactly when `ads` is empty.
        let noFillReason: VideoAdError.NoFillReason?

        private enum CodingKeys: String, CodingKey {
            case format, ads, noFillReason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(AdFormat.self, forKey: .format)
            ads = try container.decode([AdPayload].self, forKey: .ads)
            noFillReason = ads.isEmpty ? VideoAdError.NoFillReason(try? container.decodeIfPresent(String.self, forKey: .noFillReason)) : nil
        }
    }

    case formats([FormatResult])
    /// The server switched the SDK off.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case formats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Bool.self, forKey: .enabled) else {
            self = .disabled(reason: (try? container.decodeIfPresent(String.self, forKey: .disabledReason)) ?? Self.unknownReason)
            return
        }
        self = .formats(try container.decode([FormatResult].self, forKey: .formats))
    }

    /// The entry for one format, or `nil` when the server did not answer for it.
    func result(for format: AdFormat) -> FormatResult? {
        guard case .formats(let results) = self else { return nil }
        return results.first { $0.format == format }
    }
}
