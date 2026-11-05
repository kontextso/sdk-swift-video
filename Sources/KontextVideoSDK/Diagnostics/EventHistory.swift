/// The last `historyLength` debug events, kept on the device for the history an error report carries, whether or
/// not the server asked for the debug log; no sending. `DebugReporter` records into it, `ErrorReport` reads
/// `recent()`.
@MainActor
enum EventHistory {
    /// One event in the short history every error report carries: what the SDK did just before.
    struct Moment: Encodable, Sendable {
        /// When it happened: device time, ISO 8601 with milliseconds in UTC, as the event and the report write it.
        let createdAt: String
        let name: String
        let adId: String?
        let state: [String: ReportFormat.Value]?
    }

    static let historyLength = 30

    /// The state keys an error report's history may carry; anything else stays on the device.
    static let historyKeys: Set<String> = ["held", "playhead", "format", "filled", "reason", "enabled", "code", "durationMs", "step", "domain"]

    private static var moments: [Moment] = []

    /// Keeps one event; the oldest goes past `historyLength`.
    static func record(createdAt: String, name: String, adId: String?, state: [String: ReportFormat.Value]?) {
        moments.append(Moment(createdAt: createdAt, name: name, adId: adId, state: state))
        if moments.count > historyLength { moments.removeFirst(moments.count - historyLength) }
    }

    /// The recent events, reduced for an error report: listed state keys only, strings and ids capped at
    /// `ReportFormat.maxFieldLength` UTF-8 bytes.
    static func recent() -> [Moment] {
        moments.map { moment in
            let state = moment.state?.filter { historyKeys.contains($0.key) }.mapValues { value -> ReportFormat.Value in
                if case .string(let text) = value { return .string(ReportFormat.capped(text)) }
                return value
            }
            return Moment(createdAt: moment.createdAt, name: ReportFormat.capped(moment.name),
                          adId: moment.adId.map(ReportFormat.capped), state: state?.isEmpty == true ? nil : state)
        }
    }

    /// Forgets every event. Tests, and `DebugReporter.resetForTesting()`.
    static func clear() {
        moments.removeAll()
    }
}
