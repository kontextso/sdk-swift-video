/// The answer to `POST /init`.
enum InitResponse: Decodable, Sendable {
    /// `sessionTimeout` is milliseconds of inactivity after which the session ends.
    case enabled(sessionId: String, sessionTimeout: Int, reportDebug: Bool)
    /// The server switched the SDK off. The list of reasons may grow, so it stays a string.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case sessionId
        case sessionTimeout
        case reportDebug
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .enabled) {
            self = .enabled(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                sessionTimeout: try container.decode(Int.self, forKey: .sessionTimeout),
                reportDebug: try container.decodeIfPresent(Bool.self, forKey: .reportDebug) ?? false
            )
        } else {
            self = .disabled(reason: try container.decodeIfPresent(String.self, forKey: .disabledReason) ?? "unknown")
        }
    }
}
