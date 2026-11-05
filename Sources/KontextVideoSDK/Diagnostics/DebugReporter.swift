import Foundation

/// Sends the SDK's debug events to `POST /debug`, only when `/config` asked for it (`reportDebug`).
/// Events are buffered and sent in batches, at most one request per 100 ms. The body carries small
/// facts only: names, ad ids, levels, and short string/number/boolean state. Never the IFA, the IDFV,
/// the email, the user id, consent strings, request or response bodies.
@MainActor
final class DebugReporter {
    struct Event: Encodable, Sendable {
        /// Device time, ISO 8601 with milliseconds in UTC, as Kontext's APIs write wall-clock time.
        let createdAt: String
        let name: String
        let adId: String?
        let level: Level?
        let state: [String: ReportFormat.Value]?
    }

    /// Absent means `info`.
    enum Level: String, Encodable, Sendable {
        case info
        case warning
        case error
    }

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

    /// What `/config` said (`reportDebug`), read from the SDK's state: off until it answers; nothing is sent while
    /// `false`.
    var isEnabled: Bool { KontextVideo.shared.sdkState.isDebugReportingOn }

    private var buffer: [Event] = []
    private var flushTask: Task<Void, Never>?

    /// `/config` answered (`KontextVideo.recordDebugReporting`): off drops what waits.
    func reportingChanged() {
        if !isEnabled { buffer.removeAll() }
    }

    /// Back to the state before any `/config`: nothing waiting, no history. Tests only.
    func resetForTesting() {
        buffer.removeAll()
        EventHistory.clear()
    }

    private init() {}

    /// Records an event; it leaves with the next batch. Every event is also one `debug` line in the
    /// device console, in the same shape, whether or not the server asked for it.
    func event(_ name: String, adId: String? = nil, level: Level? = nil, state: [String: ReportFormat.Value]? = nil) {
        Logger.debug(Self.line(name, adId: adId, state: state))
        // One timestamp for both: the history entry and the debug event are the same moment.
        let createdAt = ReportFormat.timestamp()
        EventHistory.record(createdAt: createdAt, name: name, adId: adId, state: state)
        guard isEnabled else { return }
        buffer.append(Event(createdAt: createdAt, name: name, adId: adId, level: level, state: state))
        if buffer.count > Self.maxBuffered { buffer.removeFirst(buffer.count - Self.maxBuffered) }
        scheduleFlush()
    }

    /// `ad.loaded ad=f1a2b3c4 durationMs=842`, the event as the console shows it.
    static func line(_ name: String, adId: String?, state: [String: ReportFormat.Value]?) -> String {
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
