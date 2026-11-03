/// The answer to `POST /config`.
///
/// `enabled` is required: without it decoding fails, as in the Kotlin SDK. It is the kill switch, and a missing
/// one cannot be read either way: as `true`, a broken answer would ignore a server switching ads off (a bad
/// creative in the wild, a legal problem); as `false`, one malformed answer would disable the SDK for the whole
/// app launch. Failing instead leaves `/config` failed, and the next `format(_:)` asks again. The extras are
/// lenient: `reportDebug` and `reportErrors` default to `false`, `disabledReason` to `unknown`. The same rule
/// holds for `enabled` in the ads answer (`AdsResponse`).
enum ConfigResponse: Decodable, Sendable {
    /// `reportDebug`: when true the SDK sends its debug log to `/debug`. `reportErrors`: when true it sends
    /// its error reports to `/error`. Both are false when the server leaves them out.
    case enabled(reportDebug: Bool, reportErrors: Bool)
    /// The server switched the SDK off. The list of reasons may grow, so it stays a string.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case reportDebug
        case reportErrors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .enabled) {
            self = .enabled(reportDebug: (try? container.decodeIfPresent(Bool.self, forKey: .reportDebug)) ?? false,
                            reportErrors: (try? container.decodeIfPresent(Bool.self, forKey: .reportErrors)) ?? false)
        } else {
            self = .disabled(reason: (try? container.decodeIfPresent(String.self, forKey: .disabledReason)) ?? AdsResponse.unknownReason)
        }
    }
}
