import Foundation

/// Why `load` or `show` could not do its job. Thrown, never delivered through the delegate: a thrown error
/// means nothing happened on screen and nothing was fired.
public enum VideoAdError: Error, Sendable {
    /// What is wrong with a placement id. An integration bug: fix the id or the dashboard.
    public enum InvalidPlacement: Sendable, Equatable {
        /// No placement with this id exists for the publisher token.
        case unknown(id: String)
        /// The placement exists, with another format. `expected` is the dashboard's format when the
        /// server named it.
        case formatMismatch(id: String, expected: AdFormat?, actual: AdFormat)
    }

    /// `initialize(with:)` was not called. A debug build already stopped on an assertion when the
    /// `VideoAds` was created; a release build gets this error instead, and works once `initialize` runs.
    case notInitialized
    /// `/init` failed and is not due for a retry yet (the SDK tries again at the next video start, 5 minutes
    /// after the failure at the earliest). No ads until it succeeds.
    case initializationFailed
    /// The `VideoAds` was destroyed. It is terminal: create a new one for the next content.
    case destroyed
    /// The `KontextVideoPlayer` object was deallocated; the request needs its view and playhead. Not
    /// terminal: the ad, when there is one, stays ready.
    case playerUnavailable
    /// The server switched the SDK off for this app launch (`/init` or an ads response said so).
    case disabled(reason: String)
    /// The placement already has an ad loading, loaded but not shown, or showing. One ad per placement at
    /// a time: show it, let it end, or drop it, then load again.
    case placementBusy
    /// Timed mode: the server said not to ask for this placement again before this content time (seconds).
    case tooEarly(nextRequestAt: TimeInterval)
    /// An unknown placement id or a format that does not match the dashboard.
    case invalidPlacement(InvalidPlacement)
    /// The request succeeded and the server had nothing to show: `noAdMatch`, `frequencyCap`,
    /// `contentUnsafe`, `placementDisabled`, ... Not a failure; the app decides when to ask again.
    case noFill(reason: String)
    /// The request failed: no network, a timeout, a server error, an unexpected answer.
    case request(Error)
    /// The server had an ad, but its creative did not load: the frame page failed or did not report
    /// `ad.loaded` within 10 s. `code` is the VAST error code the SDK fired (400 for a video, 500 otherwise,
    /// or the page's own).
    case creativeFailed(code: Int)
}

extension VideoAdError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .notInitialized:
            return "KontextVideo.shared.initialize(with:) was not called"
        case .initializationFailed:
            return "/init failed; no ads until it succeeds"
        case .destroyed:
            return "the VideoAds was destroyed"
        case .playerUnavailable:
            return "the KontextVideoPlayer was deallocated"
        case .disabled(let reason):
            return "the SDK is disabled by the server (\(reason))"
        case .placementBusy:
            return "the placement already has an ad loading, loaded or showing"
        case .tooEarly(let at):
            return "timed mode: not before content time \(at) s"
        case .invalidPlacement(.unknown(let id)):
            return "placement \"\(id)\" does not exist for this publisher token"
        case .invalidPlacement(.formatMismatch(let id, let expected, let actual)):
            if let expected {
                return "placement \"\(id)\" is \(article(expected)) \(expected.rawValue) placement, not \(actual.rawValue)"
            }
            return "placement \"\(id)\" is not \(article(actual)) \(actual.rawValue) placement"
        case .noFill(let reason):
            return "no fill (\(reason))"
        case .request(let error):
            return "request failed: \(error)"
        case .creativeFailed(let code):
            return "the creative failed to load (VAST error \(code))"
        }
    }

    public var errorDescription: String? { description }

    private func article(_ format: AdFormat) -> String {
        format == .overlay || format == .interstitial ? "an" : "a"
    }
}
