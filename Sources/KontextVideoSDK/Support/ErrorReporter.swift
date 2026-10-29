import Foundation

/// Sends the SDK's faults to `POST /v2/error`: something Kontext should fix (a server or contract problem, a
/// creative or frame page that broke, UIKit refusing a presentation, an integration mistake). Never an
/// outcome the app handles (no fill, destroyed, cancelled, disabled): the server already sees those.
///
/// Off until `/config` says `reportErrors: true`; a missing field, `enabled: false` or a failed launch keep it
/// off. Before `/config` answers, reports wait in memory and leave once it turns them on, or are dropped. Every
/// fault is eligible; delivery is bounded and best effort:
/// - at most `maxBuffered` reports wait; beyond that the oldest go, and the next batch says how many;
/// - one batch at a time, at most `maxBatch` reports; a batch that fails is retried unchanged (same
///   `batchId`, same `dropped`), after a backoff from `retryDelay` doubling to `maxRetryDelay`, with jitter;
/// - the server can stop a running client at once: `410` ends reporting for this launch, any other `4xx`
///   but `429` drops that batch without a retry;
/// - nothing is stored on disk.
/// Each report carries codes and ids, never free text from a system error, and never the IFA, the IDFV, the
/// user id, the email, consent strings, request or response bodies, or URLs.
@MainActor
final class ErrorReporter {
    /// What failed. Stable: the server groups by it.
    enum Code: String, Sendable {
        case configFailed = "config.failed"
        case adsRequestFailed = "ads.request_failed"
        case adsDecodeFailed = "ads.decode_failed"
        case creativeFailed = "ad.creative_failed"
        case loadTimeout = "ad.load_timeout"
        case frameLoadFailed = "frame.load_failed"
        case processTerminated = "frame.process_terminated"
        case protocolViolation = "frame.protocol_violation"
        case presentationFailed = "ad.presentation_failed"
        case dismissalTimedOut = "ad.dismissal_timed_out"
        case skanFailed = "skan.failed"
        case emptyToken = "integration.empty_token"
        case badServerURL = "integration.bad_server_url"
        case notInitialized = "integration.not_initialized"
        case badContent = "integration.bad_content"
    }

    /// Where in the SDK it failed.
    enum Stage: String, Encodable, Sendable {
        case config, request, load, presentation, playback, attribution, integration
    }

    /// What the SDK did about it. A closed list, so the server can count by it.
    enum Recovery: String, Encodable, Sendable {
        /// A failed request left the held, valid ads in place; `format()` returns them.
        case heldAdsKept = "held_ads_kept"
        /// Nothing to show.
        case noAd = "no_ad"
        /// The ad was on screen and ended with `didEnd(.failed)`.
        case adEndedFailed = "ad_ended_failed"
        /// The ad failed before `show`; `load()` or `show` throws.
        case adDroppedBeforeShow = "ad_dropped_before_show"
        /// UIKit never finished; `didEnd` was delivered anyway.
        case didEndDelivered = "did_end_delivered"
    }

    /// A system error as a domain and a code only; its text can carry anything.
    struct Underlying: Encodable, Equatable, Sendable {
        let domain: String
        let code: Int

        init(_ error: Error) {
            let error = error as NSError
            domain = String(error.domain.prefix(ErrorReporter.maxFieldLength))
            code = error.code
        }
    }

    struct Report: Encodable, Sendable {
        let id: String
        let createdAt: String
        let code: String
        let stage: Stage
        let requestId: String?
        let sessionId: String?
        let adId: String?
        let vastCode: Int?
        let httpStatus: Int?
        let underlying: Underlying?
        /// A short machine word that narrows the code down: the SKAdNetwork step, `network`, the missing field.
        let detail: String?
        let recovery: Recovery?
        let history: [DebugReporter.Moment]
    }

    private struct Request: Encodable {
        struct OS: Encodable {
            let name: String
            let version: String
        }

        let batchId: String
        let publisherToken: String
        let installId: String
        // Read by the synthesized encoder only. swiftlint:disable:next unused_declaration
        let sdk = SDKInfo()
        let app: AppInfo
        let os: OS
        let dropped: Int
        let errors: [Report]
    }

    /// One batch, retried as it is until it leaves or the server refuses it: the server dedupes by `batchId`.
    private struct Batch {
        let id: String
        let dropped: Int
        let reports: [Report]
    }

    /// Whether reports leave: unknown until `/config` answers, then what it said.
    enum Mode: Equatable {
        case pending, on, off
    }

    static let shared = ErrorReporter()

    /// The wait before a batch leaves. A constant in spirit; a variable so the tests can shrink it.
    static var interval: TimeInterval = 0.1
    /// The first wait after a batch that did not leave; it doubles on every failure, up to `maxRetryDelay`.
    static var retryDelay: TimeInterval = 30
    static var maxRetryDelay: TimeInterval = 300
    /// Reports kept while they cannot leave; beyond this the oldest go, counted in `dropped`.
    static let maxBuffered = 200
    /// Reports in one request.
    static let maxBatch = 50
    /// Characters kept of a free-form field (`detail`, the underlying error's domain).
    nonisolated static let maxFieldLength = 64

    private(set) var mode = Mode.pending
    private(set) var buffer: [Report] = []
    /// Reports dropped for room and not yet sent in a batch.
    private(set) var dropped = 0
    /// The batch that did not leave yet, retried as it is.
    private var pendingBatch: Batch?
    private var failures = 0
    private var flushTask: Task<Void, Never>?

    /// `2026-10-21T18:00:00.482Z`. `ISO8601DateFormatter.string(from:)` is documented thread-safe.
    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    /// `/config` answered: `reportErrors` turns the reports on, anything else drops them for this launch.
    func configure(enabled: Bool) {
        guard mode != .off else { return }   // a `410` from the error endpoint is final for the launch
        if enabled {
            mode = .on
            if !buffer.isEmpty { scheduleFlush(after: Self.interval) }
        } else {
            turnOff()
        }
    }

    /// Records a fault with the SDK's recent history; it leaves with the next batch, when reports are on. The
    /// report is complete here, before any delegate call can end or release the ad it is about.
    func report(
        _ code: Code,
        stage: Stage,
        requestId: String? = nil,
        sessionId: String? = nil,
        adId: String? = nil,
        vastCode: Int? = nil,
        httpStatus: Int? = nil,
        underlying: Underlying? = nil,
        detail: String? = nil,
        recovery: Recovery? = nil
    ) {
        guard mode != .off else { return }
        let report = Report(
            id: UUID().uuidString.lowercased(),
            createdAt: Self.timestamp.string(from: Date()),
            code: code.rawValue,
            stage: stage,
            requestId: requestId,
            sessionId: sessionId,
            adId: adId,
            vastCode: vastCode,
            httpStatus: httpStatus,
            underlying: underlying,
            detail: detail.map { String($0.prefix(Self.maxFieldLength)) },
            recovery: recovery,
            history: DebugReporter.shared.recentHistory()
        )
        Logger.debug("error report \(code.rawValue)\(adId.map { " ad=\($0.prefix(8))" } ?? "")")
        buffer.append(report)
        if buffer.count > Self.maxBuffered {
            let excess = buffer.count - Self.maxBuffered
            buffer.removeFirst(excess)
            dropped += excess
        }
        if mode == .on { scheduleFlush(after: Self.interval) }
    }

    /// An ads or `/config` request's failure as the report's fields: an HTTP status, or the transport
    /// error's domain and code with `network`.
    static func fields(for error: Error) -> (httpStatus: Int?, underlying: Underlying?, detail: String?) {
        switch error as? APIError {
        case .http(let status, _)?: return (status, nil, nil)
        case .transport(let urlError)?: return (nil, Underlying(urlError), "network")
        case .decoding(let decoding)?: return (nil, Underlying(decoding), nil)
        case nil: return (nil, Underlying(error), nil)
        }
    }

    /// Back to the state before any `/config`. Tests only: the shared instance is process-wide.
    func resetForTesting() {
        flushTask?.cancel()
        flushTask = nil
        mode = .pending
        buffer.removeAll()
        dropped = 0
        pendingBatch = nil
        failures = 0
    }

    private func turnOff() {
        mode = .off
        flushTask?.cancel()
        flushTask = nil
        buffer.removeAll()
        dropped = 0
        pendingBatch = nil
    }

    /// One batch at a time: the task lives until its request answered, so a slow server gets no second request.
    private func scheduleFlush(after delay: TimeInterval) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let delivered = await flush()
            flushTask = nil
            guard mode == .on, pendingBatch != nil || !buffer.isEmpty else { return }
            scheduleFlush(after: delivered ? Self.interval : nextRetryDelay())
        }
    }

    /// Backoff with jitter: `retryDelay`, doubled per failure, capped, then 80 % to 120 % of that.
    private func nextRetryDelay() -> TimeInterval {
        let base = min(Self.maxRetryDelay, Self.retryDelay * pow(2, Double(max(0, failures - 1))))
        return base * Double.random(in: 0.8...1.2)
    }

    /// `true` when the batch left, the server refused it for good, or there was nothing to send; `false`
    /// when it waits for a retry.
    private func flush() async -> Bool {
        guard mode == .on, let configuration = KontextVideo.shared.configuration else { return true }
        let batch: Batch
        if let pendingBatch {
            batch = pendingBatch
        } else {
            guard !buffer.isEmpty else { return true }
            let reports = Array(buffer.prefix(Self.maxBatch))
            buffer.removeFirst(reports.count)
            batch = Batch(id: UUID().uuidString.lowercased(), dropped: dropped, reports: reports)
            dropped = 0
            pendingBatch = batch
        }
        let os = OSInfo.current()
        let request = Request(
            batchId: batch.id,
            publisherToken: configuration.publisherToken,
            installId: KontextVideo.installId,
            app: .current(),
            os: Request.OS(name: os.name.rawValue, version: os.version),
            dropped: batch.dropped,
            errors: batch.reports
        )
        do {
            let _: EmptyResponse = try await APIClient(baseURL: configuration.adServerURL).post("error", body: request)
            pendingBatch = nil
            failures = 0
            return true
        } catch APIError.http(let status, _) where status == 410 {
            // The server's off switch for running clients: no more reports this launch.
            Logger.debug("error reports turned off by the server")
            turnOff()
            return true
        } catch APIError.http(let status, _) where (400..<500).contains(status) && status != 429 {
            // Refused for good (a malformed body, a refused token): a retry would be refused the same way.
            Logger.debug("error batch of \(batch.reports.count) refused with \(status), dropped")
            pendingBatch = nil
            return true
        } catch {
            // Reporting never affects the SDK. The same batch goes again later; newer reports wait behind it.
            Logger.debug("error batch of \(batch.reports.count) not delivered: \(error)")
            failures += 1
            return false
        }
    }
}
