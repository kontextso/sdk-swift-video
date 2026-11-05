import Foundation

/// Sends the SDK's faults to `POST /v2/error`: something Kontext should fix (a server or contract problem, a
/// creative or frame page that broke, UIKit refusing a presentation, an integration mistake). Never an
/// outcome the app handles (no fill, destroyed, cancelled, disabled): the server already sees those.
///
/// Off until `/config` says `reportErrors: true`; a missing field, `enabled: false` or a failed launch keep it
/// off. Before `/config` answers, reports wait in memory and leave once it turns them on, or are dropped. Every
/// fault is eligible; delivery is bounded and best effort:
/// - at most `ReportQueue.maxBuffered` reports wait; beyond that the oldest go, and the next batch says how many;
/// - one batch at a time, at most `ReportQueue.maxBatch` reports; a batch that fails is retried unchanged (same
///   `batchId`, same `dropped`), after a backoff from `retryDelay` doubling to `maxRetryDelay`, with jitter;
/// - the server can stop a running client at once: `410` ends reporting for this launch, any other `4xx`
///   but `429` drops that batch without a retry;
/// - nothing is stored on disk.
/// Each report carries codes and ids, never free text from a system error, and never the IFA, the IDFV, the
/// user id, the email, consent strings, request or response bodies, or URLs.
///
/// The shell only: the mode, the scheduling, the retry delay, sending and the server's answers. A report itself is
/// `ErrorReport`, the waiting ones and their batches `ReportQueue`.
@MainActor
final class ErrorReporter {
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
        let errors: [ErrorReport]
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
    /// The server answered a batch with `410`: reporting ends for this launch, whatever `/config` said. The
    /// reporter's own fact, from its own endpoint, not the SDK's state.
    private var wasStoppedByServer = false

    /// Pending until `/config` answers, then what it said (`SdkState.isErrorReportingOn`), unless the server
    /// stopped it.
    var mode: Mode {
        if wasStoppedByServer { return .off }
        switch KontextVideo.shared.sdkState.isErrorReportingOn {
        case nil: return .pending
        case true?: return .on
        case false?: return .off
        }
    }
    /// The reports waiting, and the batches made from them.
    private(set) var queue = ReportQueue()
    /// The batch that did not leave yet, retried as it is.
    private var pendingBatch: ReportQueue.Batch?
    private var failures = 0
    private var flushTask: Task<Void, Never>?

    private init() {}

    /// `/config` answered (`KontextVideo.recordErrorReporting`): reports on send what waited, reports off drop it
    /// for this launch.
    func reportingChanged() {
        switch mode {
        case .on: if !queue.isEmpty { scheduleFlush(after: Self.interval) }
        case .off: dropAll()
        case .pending: break
        }
    }

    /// Records a fault with the SDK's recent history; it leaves with the next batch, when reports are on. The
    /// report is complete here, before any delegate call can end or release the ad it is about.
    func report(
        _ code: ErrorReport.Code,
        stage: ErrorReport.Stage,
        requestId: String? = nil,
        sessionId: String? = nil,
        adId: String? = nil,
        vastCode: Int? = nil,
        httpStatus: Int? = nil,
        underlying: ErrorReport.Underlying? = nil,
        detail: String? = nil,
        recovery: ErrorReport.Recovery? = nil
    ) {
        guard mode != .off else { return }
        let report = ErrorReport.make(code, stage: stage, requestId: requestId, sessionId: sessionId, adId: adId, vastCode: vastCode,
                                      httpStatus: httpStatus, underlying: underlying, detail: detail, recovery: recovery)
        Logger.debug("error report \(code.rawValue)\(adId.map { " ad=\($0.prefix(8))" } ?? "")")
        guard queue.add(report) else {
            Logger.debug("error report \(code.rawValue) of \(ReportQueue.size(of: report)) bytes dropped, over the batch budget")
            return
        }
        if mode == .on { scheduleFlush(after: Self.interval) }
    }

    /// A failed ads or `/config` request.
    func report(_ code: ErrorReport.Code, stage: ErrorReport.Stage, requestId: String, sessionId: String? = nil, failure: ErrorReport.FailedRequest, recovery: ErrorReport.Recovery? = nil) {
        report(code, stage: stage, requestId: requestId, sessionId: sessionId, httpStatus: failure.httpStatus,
               underlying: failure.underlying, detail: failure.detail, recovery: recovery)
    }

    /// Back to the state before any `/config`. Tests only: the shared instance is process-wide.
    func resetForTesting() {
        flushTask?.cancel()
        flushTask = nil
        wasStoppedByServer = false
        queue.clear()
        pendingBatch = nil
        failures = 0
    }

    /// Drops everything waiting: reports are off for this launch.
    private func dropAll() {
        flushTask?.cancel()
        flushTask = nil
        queue.clear()
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
            guard mode == .on, pendingBatch != nil || !queue.isEmpty else { return }
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
        guard let batch = pendingBatch ?? nextBatch(token: configuration.publisherToken) else { return true }
        pendingBatch = batch
        do {
            let _: EmptyResponse = try await APIClient(baseURL: configuration.adServerURL).post("error", encodedBody: batch.body)
            pendingBatch = nil
            failures = 0
            return true
        } catch APIError.http(let status, _) where status == 410 {
            // The server's off switch for running clients: no more reports this launch.
            Logger.debug("error reports turned off by the server")
            wasStoppedByServer = true
            dropAll()
            return true
        } catch APIError.http(let status, _) where (400..<500).contains(status) && status != 429 {
            // Refused for good (a malformed body, a refused token): a retry would be refused the same way.
            Logger.debug("error batch of \(batch.count) refused with \(status), dropped")
            pendingBatch = nil
            return true
        } catch {
            // Reporting never affects the SDK. The same batch goes again later; newer reports wait behind it.
            Logger.debug("error batch of \(batch.count) not delivered: \(error)")
            failures += 1
            return false
        }
    }

    /// The next batch from the queue, its body this launch's request: a new `batchId`, the app, the OS, the
    /// dropped count. `nil` when nothing is left to send.
    private func nextBatch(token: String) -> ReportQueue.Batch? {
        let id = UUID().uuidString.lowercased()
        let os = OSInfo.current()
        return queue.makeBatch { reports, dropped in
            try? APIClient.encode(Request(batchId: id, publisherToken: token, installId: KontextVideo.installId, app: .current(),
                                          os: Request.OS(name: os.name.rawValue, version: os.version), dropped: dropped, errors: reports))
        }
    }
}
