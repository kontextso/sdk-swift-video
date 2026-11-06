import Foundation

/// One error report: its vocabulary (what failed, where, what the SDK did) and its fields, each string capped,
/// with the recent events of `EventHistory`. Sent by `ErrorReporter`, queued by `ReportQueue`.
struct ErrorReport: Encodable, Sendable {
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
    let history: [EventHistory.Moment]

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
        let underlying: Underlying?
        let detail: String?

        init(_ error: Error) {
            switch error as? APIError {
            case .http(let status, _)?:
                httpStatus = status
                underlying = nil
                detail = nil
            case .transport(let urlError)?:
                httpStatus = nil
                underlying = Underlying(urlError)
                detail = "network"
            case .decoding(let decoding)?:
                httpStatus = nil
                underlying = Underlying(decoding)
                detail = nil
            case nil:
                httpStatus = nil
                underlying = Underlying(error)
                detail = nil
            }
        }
    }

    /// One report, made now: a new id, the timestamp, every string capped, the recent events of `EventHistory`.
    @MainActor
    static func make(
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
    ) -> ErrorReport {
        let cap = { (text: String?) in text.map { ReportFormat.capped($0) } }
        return ErrorReport(
            id: UUID().uuidString.lowercased(),
            createdAt: ReportFormat.timestamp(),
            code: code.rawValue,
            stage: stage,
            requestId: cap(requestId),
            sessionId: cap(sessionId),
            adId: cap(adId),
            vastCode: vastCode,
            httpStatus: httpStatus,
            underlying: underlying,
            detail: cap(detail),
            recovery: recovery,
            history: EventHistory.recent()
        )
    }
}
