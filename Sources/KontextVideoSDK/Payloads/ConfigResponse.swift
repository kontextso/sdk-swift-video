/// The answer to `POST /config`.
enum ConfigResponse: Decodable, Sendable {
    /// `reportDebug`: when true the SDK sends its debug log to `/debug`.
    case enabled(reportDebug: Bool)
    /// The server switched the SDK off. The list of reasons may grow, so it stays a string.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case reportDebug
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .enabled) {
            self = .enabled(reportDebug: (try? container.decodeIfPresent(Bool.self, forKey: .reportDebug)) ?? false)
        } else {
            self = .disabled(reason: (try? container.decodeIfPresent(String.self, forKey: .disabledReason)) ?? AdsResponse.unknownReason)
        }
    }
}
