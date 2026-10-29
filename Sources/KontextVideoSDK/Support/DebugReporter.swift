import Foundation

/// Sends the SDK's debug events to `POST /debug`, only when `/config` asked for it (`reportDebug`).
/// Events are buffered and sent in batches, at most one request per 100 ms. The body carries small
/// facts only: names, ad ids, levels, and short string/number/boolean state. Never the IFA, the IDFV,
/// the email, the user id, consent strings, request or response bodies.
@MainActor
final class DebugReporter {
    struct Event: Encodable, Sendable {
        /// Device time, ISO 8601 with milliseconds in UTC, as every Kontext API writes wall-clock time.
        let createdAt: String
        let name: String
        let adId: String?
        let level: Level?
        let state: [String: Value]?
    }

    /// Absent means `info`.
    enum Level: String, Encodable, Sendable {
        case info
        case warning
        case error
    }

    /// A string, a number or a boolean.
    enum Value: Encodable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
        case string(String)
        case number(Double)
        case bool(Bool)

        init(stringLiteral value: String) { self = .string(value) }
        init(integerLiteral value: Int) { self = .number(Double(value)) }
        init(booleanLiteral value: Bool) { self = .bool(value) }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }

        var description: String {
            switch self {
            case .string(let value): return value
            case .number(let value): return Int(exactly: value).map(String.init) ?? String(value)
            case .bool(let value): return String(value)
            }
        }
    }

    /// `2026-10-21T18:00:00.482Z`. `ISO8601DateFormatter.string(from:)` is documented thread-safe.
    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private struct Request: Encodable {
        let publisherToken: String
        let installId: String
        let sdk: SDKInfo
        let events: [Event]
    }

    static let shared = DebugReporter()
    /// At most one request per interval. A constant in spirit; a variable so the tests can shrink it.
    static var interval: TimeInterval = 0.1
    /// Events kept while a batch cannot leave (a slow or failing server); beyond this the oldest go.
    static let maxBuffered = 500

    /// Set from the `/config` response; nothing is sent while `false`.
    var isEnabled = false {
        didSet { if !isEnabled { buffer.removeAll() } }
    }

    private var buffer: [Event] = []
    private var flushTask: Task<Void, Never>?

    /// One event in the short history every error report carries: what the SDK did just before.
    struct Moment: Encodable, Sendable {
        /// Seconds before the error, so negative.
        let at: Double
        let name: String
        let adId: String?
        let state: [String: Value]?
    }

    /// The last events, kept whether or not the server asked for the debug log: the history of an error report.
    static let historyLength = 30
    private var history: [(time: TimeInterval, name: String, adId: String?, state: [String: Value]?)] = []

    /// Tests only, with the shared instance reset.
    func clearHistory() {
        history.removeAll()
    }

    /// The state keys an error report's history may carry; anything else stays on the device.
    static let historyKeys: Set<String> = ["held", "playhead", "format", "filled", "reason", "enabled", "code", "durationMs", "step", "domain"]

    /// The recent events, each timed relative to `now`, reduced for an error report: listed state keys only,
    /// strings and ids capped at `ErrorReporter.maxFieldLength`.
    func recentHistory(before now: TimeInterval = Environment.now()) -> [Moment] {
        let cap = ErrorReporter.maxFieldLength
        return history.map { entry in
            let state = entry.state?.filter { Self.historyKeys.contains($0.key) }.mapValues { value -> Value in
                if case .string(let text) = value { return .string(String(text.prefix(cap))) }
                return value
            }
            return Moment(at: ((entry.time - now) * 1000).rounded() / 1000, name: String(entry.name.prefix(cap)),
                          adId: entry.adId.map { String($0.prefix(cap)) }, state: state?.isEmpty == true ? nil : state)
        }
    }

    private init() {}

    /// Records an event; it leaves with the next batch. Every event is also one `debug` line in the
    /// device console, in the same shape, whether or not the server asked for it.
    func event(_ name: String, adId: String? = nil, level: Level? = nil, state: [String: Value]? = nil) {
        Logger.debug(Self.line(name, adId: adId, state: state))
        history.append((Environment.now(), name, adId, state))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        guard isEnabled else { return }
        buffer.append(Event(createdAt: Self.timestamp.string(from: Date()), name: name, adId: adId, level: level, state: state))
        if buffer.count > Self.maxBuffered { buffer.removeFirst(buffer.count - Self.maxBuffered) }
        scheduleFlush()
    }

    /// `ad.loaded ad=f1a2b3c4 durationMs=842`, the event as the console shows it.
    static func line(_ name: String, adId: String?, state: [String: Value]?) -> String {
        var parts = [name]
        if let adId { parts.append("ad=\(adId.prefix(8))") }
        for (key, value) in (state ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(value)")
        }
        return parts.joined(separator: " ")
    }

    /// One batch at a time: the task lives until its request answered, so a slow server gets no second
    /// request; events that arrived meanwhile leave with the next batch.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            guard let self else { return }
            await flush()
            flushTask = nil
            if isEnabled, !buffer.isEmpty { scheduleFlush() }
        }
    }

    private func flush() async {
        guard isEnabled, !buffer.isEmpty, let configuration = KontextVideo.shared.configuration else { return }
        let events = buffer
        buffer.removeAll()
        let request = Request(publisherToken: configuration.publisherToken, installId: KontextVideo.installId, sdk: SDKInfo(), events: events)
        let client = APIClient(baseURL: configuration.adServerURL)
        do {
            let _: EmptyResponse = try await client.post("debug", body: request)
        } catch {
            // Debug reporting never affects the SDK; a lost batch is lost.
            Logger.debug("debug batch of \(events.count) not delivered: \(error)")
        }
    }
}
