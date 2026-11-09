import Foundation

/// The answer to `POST /config`.
///
/// `enabled` is required: without it decoding fails, as in the Kotlin SDK. It is the kill switch, and a missing
/// one cannot be read either way: as `true`, a broken answer would ignore a server switching ads off (a bad
/// creative in the wild, a legal problem); as `false`, one malformed answer would disable the SDK for the whole
/// app launch. Failing instead leaves `/config` failed, and the next `format(_:)` asks again. The extras are
/// lenient: `reportDebug` and `reportErrors` default to `false`, the batch intervals to `defaultBatchInterval`,
/// `disabledReason` to `unknown`. The same rule holds for `enabled` in the ads answer (`AdsResponse`).
enum ConfigResponse: Decodable, Sendable {
    /// What the server asks of the SDK's reporters.
    struct Reporting: Equatable, Sendable {
        /// When true the SDK sends its debug log to `/debug`.
        let reportDebug: Bool
        /// When true the SDK sends its error reports to `/error`.
        let reportErrors: Bool
        /// How long error reports are collected before they leave as one batch; 0 sends each as it happens.
        let errorBatchInterval: TimeInterval
        /// The same for debug events.
        let debugBatchInterval: TimeInterval
    }

    /// The wait before a batch leaves when the server names none.
    static let defaultBatchInterval: TimeInterval = 0.1

    case enabled(Reporting)
    /// The server switched the SDK off. The list of reasons may grow, so it stays a string.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case reportDebug
        case reportErrors
        case errorBatchInterval
        case debugBatchInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .enabled) {
            self = .enabled(Reporting(reportDebug: (try? container.decodeIfPresent(Bool.self, forKey: .reportDebug)) ?? false,
                                      reportErrors: (try? container.decodeIfPresent(Bool.self, forKey: .reportErrors)) ?? false,
                                      errorBatchInterval: Self.interval(container, .errorBatchInterval),
                                      debugBatchInterval: Self.interval(container, .debugBatchInterval)))
        } else {
            self = .disabled(reason: AdsResponse.reason(try? container.decodeIfPresent(String.self, forKey: .disabledReason)))
        }
    }

    /// A batch interval as the server writes it, in milliseconds, as seconds; absent, not a number or negative
    /// means `defaultBatchInterval`.
    private static func interval(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> TimeInterval {
        guard let milliseconds = try? container.decodeIfPresent(Double.self, forKey: key), milliseconds.isFinite, milliseconds >= 0 else {
            return defaultBatchInterval
        }
        return milliseconds / 1000
    }
}
