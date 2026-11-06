import Foundation

/// Why the SDK could not do its job, reached two ways.
///
/// - Thrown by a call (`format`, `load`, `show`): that call did not happen. Nothing is
///   shown; the only beacon a failed call fires is a failed `load()`'s VAST `error`. Whether the ad stays
///   usable is said per case.
/// - Delivered through `videoAd(_:didFail:)`, after a `show` that was accepted: the ad broke on screen
///   (`creativeFailed`), or UIKit never presented a linear ad (`cannotShowNow`). `didEnd(.failed)`
///   follows and the ad is over.
public enum VideoAdError: Error, Sendable, Equatable {
    /// `initialize(with:)` was not called. A debug build already stopped on an assertion; a release build
    /// gets this error instead, and works once `initialize` runs.
    case notInitialized
    /// `/config` failed, and so did the attempt this `format()` made. Every `format()` tries it again; no ads
    /// until it succeeds.
    case initializationFailed
    /// The `VideoAds` was destroyed. It is terminal: create a new one for the next content.
    case destroyed
    /// The server switched the SDK off for this app launch (`/config` or an ads response said so). Loaded
    /// ads cannot be shown either; an ad already on screen finishes normally.
    case disabled(reason: String)
    /// The request succeeded and the server had nothing for this format. Not a failure, and never retried
    /// by the SDK; the app decides when to ask again.
    case noFill(reason: NoFillReason)
    /// The request failed: its `RequestFailure` says why (no network, a timeout, a server error, an
    /// unexpected answer). Thrown only when the SDK holds no valid ad for the format; otherwise `format()`
    /// returns that one. Never retried by the SDK; the app decides when to ask again. The underlying error
    /// is in the SDK's console log, with the request's id.
    case request(RequestFailure)
    /// The creative failed. Thrown by `load()` when the frame page failed or did not report `ad.loaded`
    /// within 10 s of active time; delivered through `didFail` when it broke on screen. `code` is the VAST
    /// error code the SDK fired (400 for a video, 500 otherwise, 405 after show, or the page's own).
    case creativeFailed(code: Int)

    // `show`

    /// The ad was already shown: it cannot be shown again.
    case alreadyShown
    /// Another ad is on screen, from any `VideoAds`: at most one in the whole app. This ad is untouched
    /// and still ready: show it once the other one ended.
    case anotherAdShowing
    /// The ad ended before it was shown: it expired, was rejected, or its creative died. `show` throws it from
    /// then on, and so does `load()`, except for a dead creative, which `load()` throws as
    /// `creativeFailed(code:)` (see `VideoAd.invalidationReason`). Never with `.destroyed`: the ads of a
    /// destroyed `VideoAds` throw `destroyed`, the one spelling.
    case invalidated(VideoAd.InvalidationReason)

    /// `show` before `load()` finished: nothing is rendered yet. The ad stays as it was.
    case notLoaded
    /// `show(in:)` on an overlay while the content of its `VideoAds` is paused (with a player tracked by
    /// `track(_:)`): an overlay runs over playing content only. The ad stays ready: show it once the
    /// content plays again.
    case contentPaused
    /// No variant of the ad fits the view: it would have to shrink below 50 % (aspect ratio kept), or at
    /// all for a creative marked not scalable. `minimum` is the smallest view that holds it, its safe area
    /// included (the ad stays inside the safe area). The ad stays ready:
    /// show it in a bigger view, or reject it.
    case containerTooSmall(minimum: CGSize)
    /// Nothing on screen can hold the ad. Thrown by `show`: for a linear ad the view controller given is
    /// already presenting or not on screen, or with `show()` there is no key window or its top controller
    /// is mid-transition; for an overlay or pause ad the view is not in a window, or no part of it is inside
    /// its window (a pager's neighbour page, a view scrolled away), or the app presented another view controller
    /// over the one holding it (a sheet, a full-screen cover). In both, a view that is
    /// hidden, transparent or without an area, or sits in a hidden or transparent ancestor or window, is not
    /// on screen; nor is anything while the app is not active or the window's scene is not in the foreground
    /// and active (the content in Picture in Picture only, the lock screen, background audio, Control Center
    /// over the app): show once the app is back in front. The ad stays ready: try
    /// again later, or pass the right view or controller. Delivered through `didFail` when `show` was
    /// accepted but UIKit never presented the linear ad; the ad is over then.
    case cannotShowNow
    /// The call does not fit the format: `show(from:)` on an overlay or pause ad, `show(in:)` on a linear ad. A
    /// programmer error: a debug build already stopped on an assertion at the call. The ad stays as it was.
    case wrongShowMethod
}

extension VideoAdError {
    /// Why the server had nothing for a format: its reasons, the SDK's own `alreadyUsed`, and `other` for
    /// a reason this SDK version does not know, passed through unchanged.
    public enum NoFillReason: Sendable, Equatable, CustomStringConvertible {
        /// No campaign matched the content, the viewer or the moment.
        case noAdMatch
        /// The content is not brand safe.
        case contentUnsafe
        /// No configuration for this format in the Kontext dashboard: the integration, not the moment.
        case formatNotEnabled
        /// The viewer has seen enough ads for now.
        case frequencyCap
        /// Not served in this country.
        case geoRestricted
        /// The server's side; ask again later.
        case temporaryError
        /// The SDK's own: the answer was an ad the app had just shown or rejected while the request ran.
        case alreadyUsed
        /// The server gave no reason, or one the SDK could not read.
        case unknown
        /// A reason this SDK version does not know, as the server sent it.
        case other(String)

        /// The wire name, for logs.
        public var description: String {
            switch self {
            case .noAdMatch: return "noAdMatch"
            case .contentUnsafe: return "contentUnsafe"
            case .formatNotEnabled: return "formatNotEnabled"
            case .frequencyCap: return "frequencyCap"
            case .geoRestricted: return "geoRestricted"
            case .temporaryError: return "temporaryError"
            case .alreadyUsed: return "alreadyUsed"
            case .unknown: return "unknown"
            case .other(let raw): return raw
            }
        }
    }
}

extension VideoAdError {
    /// Why an ads request failed, in four outcomes an app can act on. Unlike a no-fill, the server's answer
    /// for the moment is unknown: asking again later may fill.
    public enum RequestFailure: Sendable, Equatable, CustomStringConvertible {
        /// The request did not get through: no connection, the connection lost, the server's name or
        /// address unreachable, a secure connection that failed (often a captive portal). Ask again once
        /// the device is back online, for example at the next episode or the next pause.
        case offline
        /// The server did not answer in time (10 s). The network is slow or the server is busy: ask again
        /// later, not straight away.
        case timedOut
        /// The server answered with an error status: `status` is the HTTP status (5xx, or any other the
        /// contract does not expect, 4xx included). Ask again later; quote `VideoAds.lastRequestID` to
        /// Kontext when it repeats.
        case server(status: Int)
        /// An answer arrived and the SDK could not use it: not the JSON of the contract, malformed (one bid
        /// under two formats, for example), cut off or over the size limit. Asking again soon is unlikely
        /// to help; quote `VideoAds.lastRequestID` to Kontext.
        case badResponse

        /// The case's name, for logs: `offline`, `timedOut`, `server(503)`, `badResponse`.
        public var description: String {
            switch self {
            case .offline: return "offline"
            case .timedOut: return "timedOut"
            case .server(let status): return "server(\(status))"
            case .badResponse: return "badResponse"
            }
        }
    }
}

extension VideoAdError: CustomStringConvertible, LocalizedError {
    /// A sentence for logs and crash reports: what went wrong and, where it helps, what to do.
    public var description: String {
        switch self {
        case .notInitialized:
            return "KontextVideo.shared.initialize(with:) was not called"
        case .initializationFailed:
            return "/config failed, and trying it again failed too; no ads until it succeeds"
        case .destroyed:
            return "the VideoAds was destroyed"
        case .disabled(let reason):
            return "the SDK is disabled by the server (\(reason))"
        case .noFill(let reason):
            return "no fill (\(reason))"
        case .request(let failure):
            return "request failed (\(failure))"
        case .creativeFailed(let code):
            return "the creative failed (VAST error \(code))"
        case .alreadyShown:
            return "the ad was already shown"
        case .anotherAdShowing:
            return "another ad is on screen; show this one after it ended"
        case .invalidated(let reason):
            return "the ad ended before it was shown (\(reason))"
        case .notLoaded:
            return "the ad is not loaded yet; call load() first"
        case .contentPaused:
            return "the content is paused; show the overlay once it plays"
        case .containerTooSmall(let minimum):
            return "the view is too small for the ad; at least \(Self.points(minimum.width))×\(Self.points(minimum.height)) points are needed"
        case .cannotShowNow:
            return "the ad cannot be shown now: the view or view controller is not on screen, or the app is not in front"
        case .wrongShowMethod:
            return "this call does not fit the ad's format (show(in:) for overlay and pause, show(from:) for linear)"
        }
    }

    /// The same sentence as `description`, for `localizedDescription`. English only.
    public var errorDescription: String? { description }

    /// A dimension for the description, never a trap: whole points as an integer, anything else as it is.
    private static func points(_ value: CGFloat) -> String {
        Int(exactly: value).map(String.init) ?? "\(value)"
    }
}
