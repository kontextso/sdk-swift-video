import Foundation
import UIKit

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
    /// `/init` failed, and the retry this `load` made failed too. Every `load` retries it; no ads until
    /// it succeeds.
    case initializationFailed
    /// The `VideoAds` was destroyed. It is terminal: create a new one for the next content.
    case destroyed
    /// The server switched the SDK off for this app launch (`/init` or an ads response said so).
    case disabled(reason: String)
    /// The placement already has an ad loading, or loaded but not shown. One unshown ad per placement at
    /// a time: show it or drop it, then load again. An ad on screen does not block the next load.
    case placementBusy
    /// Three rendered, unshown ads already exist across the app's `VideoAds` (the render budget: a
    /// rendered ad is a live WebView with its media; fetched bids do not count). Show or drop one first;
    /// to prefetch several episodes, `fetch()` early and `bid.load()` near presentation.
    case tooManyLoadedAds
    /// An unknown placement id or a format that does not match the dashboard.
    case invalidPlacement(InvalidPlacement)
    /// The request succeeded and the server had nothing to show: `noAdMatch`, `frequencyCap`,
    /// `contentUnsafe`, `placementDisabled`, `temporaryError`, ... Not a failure, and never retried by
    /// the SDK; the app decides when to ask again.
    case noFill(reason: String)
    /// The request failed: no network, a timeout, a server error, an unexpected answer.
    case request(Error)
    /// The server had an ad, but its creative did not load: the frame page failed or did not report
    /// `ad.loaded` within 10 s. `code` is the VAST error code the SDK fired (400 for a video, 500 otherwise,
    /// or the page's own).
    case creativeFailed(code: Int)

    // `show`

    /// An ad is shown at most once.
    case alreadyShown
    /// Another ad of this `VideoAds` is on screen; at most one is presented at a time, whatever the
    /// formats. This ad is untouched and still ready: `dismiss()` the other, then show.
    case anotherAdShowing
    /// The ad was lost before `show`; the delegate's `didInvalidate` had the same reason.
    case invalidated(VideoAd.InvalidationReason)
    /// The player's view is below 50 % of the ad's size. The ad is discarded; load again with the real size.
    case containerTooSmall(minimum: CGSize)
    /// No view controller can present the linear ad right now: the one given is already presenting or
    /// not on screen; with `show()`, there is no key window or its top controller is mid-transition or a
    /// system alert or sheet. The ad stays ready: try again later, or pass the right controller. Also
    /// thrown in a release build when the wrong `show` is used for the format.
    case presenterUnavailable
}

extension VideoAdError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .notInitialized:
            return "KontextVideo.shared.initialize(with:) was not called"
        case .initializationFailed:
            return "/init failed, and retrying it failed too; no ads until it succeeds"
        case .destroyed:
            return "the VideoAds was destroyed"
        case .disabled(let reason):
            return "the SDK is disabled by the server (\(reason))"
        case .placementBusy:
            return "the placement already has an ad loading, or loaded and not yet shown"
        case .tooManyLoadedAds:
            return "\(VideoAds.renderBudget) rendered ads are waiting to be shown; show or drop one first"
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
        case .alreadyShown:
            return "the ad was already shown"
        case .anotherAdShowing:
            return "another ad of this VideoAds is on screen; dismiss it first"
        case .invalidated(let reason):
            return "the ad was invalidated (\(reason))"
        case .containerTooSmall(let minimum):
            return "the player's view is too small for the ad; at least \(Int(minimum.width))×\(Int(minimum.height)) points are needed"
        case .presenterUnavailable:
            return "no view controller can present the ad now"
        }
    }

    public var errorDescription: String? { description }

    private func article(_ format: AdFormat) -> String {
        format == .overlay || format == .linear ? "an" : "a"
    }
}
