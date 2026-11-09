import Foundation

/// Sends the SDK's debug events to `POST /debug`, only when `/config` asked for it (`reportDebug`): the
/// structured events (`ads.request`, `ad.loaded`, …) and, as the event `log`, every line `Logger` writes to the
/// console, whatever the console level. Events are buffered and sent in batches, one every `interval` as
/// `/config` set it (0: no wait; what arrives while a request is in flight leaves together after it). The
/// structured events carry names, ids, levels and short string/number/boolean properties, never the IFA, the
/// IDFV, the email, the user id, consent strings, request or response bodies. A console line goes as written,
/// uncapped, with every URL's query removed (a filled macro can hold the IFA); what else the SDK logs is what
/// the server may read, here and in an error report's history.
@MainActor
final class DebugReporter {
    struct Event: Encodable, Sendable {
        /// Device time, ISO 8601 with milliseconds in UTC, as Kontext's APIs write wall-clock time.
        let occurredAt: String
        let name: String
        /// The `VideoAds` (episode) the event is about; `nil` for an SDK-wide one.
        let sessionId: String?
        /// The ad the event is about, by the id the server gave the bid.
        let bidId: String?
        let level: Level?
        let properties: [String: ReportFormat.Value]?
    }

    /// Absent means `info`.
    enum Level: String, Encodable, Sendable {
        case debug
        case info
        case warning
        case error

        /// The console level as the event's; `nil` for `.none`, which no message has.
        init?(_ level: KontextVideo.Configuration.LogLevel) {
            switch level {
            case .none: return nil
            case .error: self = .error
            case .warning: self = .warning
            case .info: self = .info
            case .debug: self = .debug
            }
        }
    }

    private struct Request: Encodable {
        let publisherToken: String
        let installId: String
        let sdk: SDKInfo
        let app: AppInfo
        let os: ReportFormat.OS
        let events: [Event]
    }

    static let shared = DebugReporter()
    /// Events kept while a batch cannot leave (a slow or failing server); beyond this the oldest go.
    static let maxBuffered = 500

    /// The wait before a batch leaves, as `/config` set it (`debugBatchInterval`); 0 waits for nothing but a request in flight.
    var interval: TimeInterval = ConfigResponse.defaultBatchInterval

    /// What `/config` said (`reportDebug`), read from the SDK's state: off until it answers; nothing is sent while
    /// `false`.
    var isEnabled: Bool { KontextVideo.shared.sdkState.isDebugReportingOn }

    /// `isEnabled`, readable from any thread: `Logger` asks before it builds a line the console would not show.
    nonisolated static var forwardsConsole: Bool { lock.withLock { storedForwardsConsole } }
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var storedForwardsConsole = false

    private var buffer: [Event] = []
    private var flushTask: Task<Void, Never>?

    /// `/config` answered (`KontextVideo.recordDebugReporting`): off drops what waits.
    func reportingChanged() {
        let enabled = isEnabled
        Self.lock.withLock { Self.storedForwardsConsole = enabled }
        if !enabled { buffer.removeAll() }
    }

    /// Back to the state before any `/config`: nothing waiting, no history. Tests only.
    func resetForTesting() {
        buffer.removeAll()
        EventHistory.clear()
        interval = ConfigResponse.defaultBatchInterval
        Self.lock.withLock { Self.storedForwardsConsole = false }
    }

    private init() {}

    /// Records an event; it leaves with the next batch. Every event is also one `debug` line in the
    /// device console, in the same shape, whether or not the server asked for it.
    func event(_ name: String, sessionId: String? = nil, bidId: String? = nil, level: Level? = nil, properties: [String: ReportFormat.Value]? = nil) {
        // Every string capped as the event is kept, as an error report's are (`ReportFormat.maxFieldLength`, as on
        // Android): the history and the buffer hold these for the app's life, and an ad id has no length limit.
        let name = ReportFormat.capped(name)
        let bidId = bidId.map { ReportFormat.capped($0) }
        let properties = properties?.mapValues { value -> ReportFormat.Value in
            if case .string(let text) = value { return .string(ReportFormat.capped(text)) }
            return value
        }
        Logger.console(.debug, Self.line(name, bidId: bidId, properties: properties))
        record(Event(occurredAt: ReportFormat.timestamp(), name: name, sessionId: sessionId, bidId: bidId, level: level, properties: properties))
    }

    /// A line `Logger` wrote, as the event `log` with the line as `message`, uncapped: the console's story of the
    /// install. From any thread; the time is the line's, the event is made and recorded on the main actor.
    nonisolated static func forward(_ level: KontextVideo.Configuration.LogLevel, _ message: String) {
        guard let level = Level(level) else { return }
        let at = Date()
        Task { @MainActor in
            let text = withoutQueryStrings(message)
            shared.record(Event(occurredAt: ReportFormat.timestamp(at), name: "log", sessionId: nil, bidId: nil, level: level, properties: ["message": .string(text)]))
        }
    }

    /// `ad.loaded ad=f1a2b3c4 durationMs=842`, the event as the console shows it.
    static func line(_ name: String, bidId: String?, properties: [String: ReportFormat.Value]?) -> String {
        var parts = [name]
        if let bidId { parts.append("ad=\(bidId.prefix(8))") }
        for (key, value) in (properties ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(value)")
        }
        return parts.joined(separator: " ")
    }

    /// `text` with the query cut from every URL in it, whatever its scheme or case, `//` or not (a deep link such as
    /// `app:offer?x`): a filled macro can carry the IFA.
    static func withoutQueryStrings(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\b([a-z][a-z0-9+.-]*:(?://)?[^\s?#]+)\?[^\s]*"#, with: "$1", options: .regularExpression)
    }

    /// One event kept: in the history every error report carries, and, while `/config` asks for the debug log,
    /// in the next batch.
    private func record(_ event: Event) {
        EventHistory.record(event)
        guard isEnabled else { return }
        buffer.append(event)
        if buffer.count > Self.maxBuffered { buffer.removeFirst(buffer.count - Self.maxBuffered) }
        scheduleFlush()
    }

    /// One batch at a time: the task lives until its request answered, so a slow server gets no second
    /// request; events that arrived meanwhile leave with the next batch.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            if let interval = self?.interval, interval > 0 { try? await Task.sleep(seconds: interval) }
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
        let request = Request(publisherToken: configuration.publisherToken, installId: KontextVideo.installId, sdk: SDKInfo(),
                              app: .current(), os: ReportFormat.os(), events: events)
        let client = APIClient(baseURL: configuration.adServerURL)
        do {
            let _: EmptyResponse = try await client.post("debug", body: request)
        } catch {
            // Debug reporting never affects the SDK; a lost batch is lost. The console line about it is not forwarded:
            // it would make the next batch, and fail the same way.
            Logger.console(.debug, "debug batch of \(events.count) not delivered: \(error)")
        }
    }
}
