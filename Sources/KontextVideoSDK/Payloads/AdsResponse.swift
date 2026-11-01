/// The answer to `POST /video/ads`: one entry per format (the SDK always asks for all of them), each with
/// its ads or its no-fill reason; or the kill switch. `nextRequestAt` (timed mode) is on the wire but
/// not read: the SDK has no timed mode yet, every ad is shown at a moment the app picks.
enum AdsResponse: Decodable, Sendable {
    /// Stands in for a `disabledReason` the server left out or sent malformed; the answer itself is
    /// still understood. (`NoFillReason.unknown` is the same for a no-fill.)
    static let unknownReason = "unknown"

    /// One per format. `ads` is a sequence, the first to be shown first; today a filled entry
    /// carries one. Strict on `format` and on `ads` being a list of ads of that format (they decide the
    /// answer), lenient on the reason. Each ad decodes on its own: one that does not is dropped and named
    /// in `dropped`, and the others, and the other formats, stay. A format left with no valid ad is a
    /// no-fill with reason `unknown`.
    struct FormatResult: Decodable, Sendable {
        let format: AdFormat
        let ads: [AdPayload]
        /// Set exactly when `ads` is empty.
        let noFillReason: VideoAdError.NoFillReason?
        /// Where each dropped ad failed to decode: the field path inside the ad (`price.currency`), for the
        /// error report. Empty when every ad decoded.
        let dropped: [String]

        fileprivate enum CodingKeys: String, CodingKey {
            case format, ads, noFillReason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(container, format: try container.decode(AdFormat.self, forKey: .format))
        }

        fileprivate init(_ container: KeyedDecodingContainer<CodingKeys>, format: AdFormat) throws {
            self.format = format
            let attempts = try container.decode([Attempt<AdPayload>].self, forKey: .ads)
            ads = attempts.compactMap(\.value)
            dropped = attempts.compactMap(\.failure)
            // The SDK files the ad under the result's format and finds it again by the ad's own: both must agree.
            if let stray = ads.first(where: { $0.format != format }) {
                throw DecodingError.dataCorruptedError(forKey: .ads, in: container, debugDescription: "ad \(stray.id) is \(stray.format), the result is \(format)")
            }
            if ads.isEmpty {
                // Every ad of a filled entry dropped: a no-fill, its reason unknown whatever the entry says.
                noFillReason = dropped.isEmpty ? VideoAdError.NoFillReason(try? container.decodeIfPresent(String.self, forKey: .noFillReason)) : .unknown
            } else {
                noFillReason = nil
            }
        }
    }

    /// A `formats` entry: a result, or `nil` for a format this SDK does not know (one added after it
    /// shipped), which is ignored rather than failing the answer.
    private struct Entry: Decodable {
        let result: FormatResult?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FormatResult.CodingKeys.self)
            let name = try container.decode(String.self, forKey: .format)
            guard let format = AdFormat(rawValue: name) else {
                Logger.debug("ads response: format \(name) is unknown to this SDK, ignored")
                result = nil
                return
            }
            result = try FormatResult(container, format: format)
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
        let results = try container.decode([Entry].self, forKey: .formats).compactMap(\.result)
        // One entry per format: with two, which one counts would depend on their order.
        guard Set(results.map(\.format)).count == results.count else {
            throw DecodingError.dataCorruptedError(forKey: .formats, in: container, debugDescription: "a format is listed twice")
        }
        // One auction, one id: the same id under two formats would let one bid be rejected in one and shown
        // in the other (a notUsed, then an impression). The whole answer is malformed, as with a format twice.
        let ids = results.flatMap { $0.ads.map(\.id) }
        guard Set(ids).count == ids.count else {
            throw DecodingError.dataCorruptedError(forKey: .formats, in: container, debugDescription: "an ad id is listed twice")
        }
        self = .formats(results)
    }

    /// The entry for one format, or `nil` when the server did not answer for it.
    func result(for format: AdFormat) -> FormatResult? {
        guard case .formats(let results) = self else { return nil }
        return results.first { $0.format == format }
    }
}

/// One element of a list that may not decode: the value, or where it failed, and the list goes on. A
/// failing element still advances the container, which a plain `try?` on the element would not.
private struct Attempt<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    /// The failing field's path inside the element (`price.currency`), `nil` when it decoded.
    let failure: String?

    init(from decoder: Decoder) throws {
        do {
            value = try Wrapped(from: decoder)
            failure = nil
        } catch {
            value = nil
            failure = Self.path(of: error, below: decoder.codingPath.count)
        }
    }

    /// The coding path of a decoding error below the element, keys only; `ad` when it failed at the element.
    private static func path(of error: Error, below depth: Int) -> String {
        let context: DecodingError.Context?
        switch error as? DecodingError {
        case .dataCorrupted(let found), .keyNotFound(_, let found), .typeMismatch(_, let found), .valueNotFound(_, let found): context = found
        default: context = nil
        }
        var keys = (context?.codingPath ?? []).dropFirst(depth).filter { $0.intValue == nil }.map(\.stringValue)
        if case .keyNotFound(let key, _)? = error as? DecodingError { keys.append(key.stringValue) }
        return keys.isEmpty ? "ad" : keys.joined(separator: ".")
    }
}
