import Foundation

/// One error report: what failed and the ids it concerns, each string capped, with the recent events of
/// `EventHistory`. Sent by `ErrorReporter`, queued by `ReportQueue`.
struct ErrorReport: Encodable, Sendable {
    let id: String
    /// Device time, ISO 8601 with milliseconds in UTC, as Kontext's APIs write wall-clock time.
    let occurredAt: String
    let code: String
    /// The ads or `/config` request that failed, by the id the SDK gave it.
    let requestId: String?
    let sessionId: String?
    /// The ad the fault is about, by the id the server gave the bid.
    let bidId: String?
    let vastCode: Int?
    let httpStatus: Int?
    let cause: Cause?
    /// A short machine word that narrows the code down: the SKAdNetwork step, `network`, the missing field.
    let detail: String?
    let history: [DebugReporter.Event]

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

    /// The system error behind a fault, as a domain and a code only; its text can carry anything.
    struct Cause: Encodable, Equatable, Sendable {
        let domain: String
        let code: Int

        init(_ error: Error) {
            let error = error as NSError
            domain = ReportFormat.capped(error.domain)
            code = error.code
        }

        /// A page answered with an error status: domain `http`, the status as the code, as the Kotlin SDK sends it.
        init(httpStatus: Int) {
            domain = "http"
            code = httpStatus
        }
    }

    /// An ads or `/config` request's failure as the report's fields: an HTTP status, or the transport
    /// error's domain and code with `network`. Not the public `VideoAdError.RequestFailure`, which is what the
    /// app hears.
    struct FailedRequest: Sendable {
        let httpStatus: Int?
        let cause: Cause?
        let detail: String?

        init(_ error: Error) {
            switch error as? APIError {
            case .http(let status, _)?:
                httpStatus = status
                cause = nil
                detail = nil
            case .transport(let urlError)?:
                httpStatus = nil
                cause = Cause(urlError)
                detail = "network"
            case .decoding(let decoding)?:
                httpStatus = nil
                cause = Cause(decoding)
                detail = nil
            case nil:
                httpStatus = nil
                cause = Cause(error)
                detail = nil
            }
        }
    }

    /// One report, made now: a new id, the timestamp, every string capped, the recent events of `EventHistory`.
    @MainActor
    static func make(
        _ code: Code,
        requestId: String? = nil,
        sessionId: String? = nil,
        bidId: String? = nil,
        vastCode: Int? = nil,
        httpStatus: Int? = nil,
        cause: Cause? = nil,
        detail: String? = nil
    ) -> ErrorReport {
        let cap = { (text: String?) in text.map { ReportFormat.capped($0) } }
        return ErrorReport(
            id: UUID().uuidString.lowercased(),
            occurredAt: ReportFormat.timestamp(),
            code: code.rawValue,
            requestId: cap(requestId),
            sessionId: cap(sessionId),
            bidId: cap(bidId),
            vastCode: vastCode,
            httpStatus: httpStatus,
            cause: cause,
            detail: cap(detail),
            history: EventHistory.recent()
        )
    }
}
