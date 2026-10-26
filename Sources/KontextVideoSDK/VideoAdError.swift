import Foundation

/// Why a call could not do its job. Thrown, never delivered through the delegate: a thrown error means
/// nothing happened on screen and nothing was fired.
public enum VideoAdError: Error, Sendable {
    /// `initialize(with:)` was not called. A debug build already stopped on an assertion; a release build
    /// gets this error instead, and works once `initialize` runs.
    case notInitialized
    /// `/config` failed, and the retry this `format()` made failed too. Every `format()` retries it; no ads
    /// until it succeeds.
    case initializationFailed
    /// The `VideoAds` was destroyed. It is terminal: create a new one for the next content.
    case destroyed
    /// The server switched the SDK off for this app launch (`/config` or an ads response said so). Loaded
    /// ads cannot be shown either; an ad already on screen finishes normally.
    case disabled(reason: String)
    /// The request succeeded and the server had nothing for this format: `noAdMatch`, `frequencyCap`,
    /// `contentUnsafe`, `formatNotEnabled` (no configuration for this format in the Kontext dashboard),
    /// `temporaryError`, ..., or the SDK's own `alreadyUsed` (the answer was an ad the app had just shown or
    /// rejected while the request ran). Not a failure, and never retried by the SDK; the app decides when
    /// to ask again.
    case noFill(reason: String)
    /// The request failed: no network, a timeout, a server error, an unexpected answer. Thrown only when
    /// the SDK holds no valid ad for the format; otherwise `format()` returns that one.
    case request(Error)
    /// The creative did not load: the frame page failed or did not report `ad.loaded` within 10 s
    /// of active time. `code` is the VAST error code the SDK fired (400 for a video, 500 otherwise, or the
    /// page's own).
    case creativeFailed(code: Int)

    // `show`, `reject`, `dismiss`

    /// The ad was already shown: it cannot be shown again, nor rejected.
    case alreadyShown
    /// Another ad is on screen, from any `VideoAds`: at most one in the whole app. This ad is untouched
    /// and still ready: show it once the other one ended.
    case anotherAdShowing
    /// The ad ended before it was shown: it expired, was rejected, or its creative died. `load()`, `show`
    /// and `reject()` throw it from then on.
    case invalidated(VideoAd.InvalidationReason)
    /// `show` before `load()` finished: nothing is rendered yet. The ad stays as it was.
    case notLoaded
    /// The ad would have to be scaled below 50 % to fit the view (aspect ratio kept). The ad stays ready:
    /// show it in a bigger view, or reject it.
    case containerTooSmall(minimum: CGSize)
    /// No view controller can present the linear ad right now: the one given is already presenting or
    /// not on screen; with `show()`, there is no key window or its top controller is mid-transition. The ad
    /// stays ready: try again later, or pass the right controller.
    case presenterUnavailable
    /// The call does not fit the format: `show()` on an overlay or pause ad, `show(in:)` on a linear ad,
    /// `dismiss()` on a linear ad. The ad stays as it was.
    case wrongPresentation
}

extension VideoAdError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .notInitialized:
            return "KontextVideo.shared.initialize(with:) was not called"
        case .initializationFailed:
            return "/config failed, and retrying it failed too; no ads until it succeeds"
        case .destroyed:
            return "the VideoAds was destroyed"
        case .disabled(let reason):
            return "the SDK is disabled by the server (\(reason))"
        case .noFill(let reason):
            return "no fill (\(reason))"
        case .request(let error):
            return "request failed: \(error)"
        case .creativeFailed(let code):
            return "the creative failed to load (VAST error \(code))"
        case .alreadyShown:
            return "the ad was already shown"
        case .anotherAdShowing:
            return "another ad is on screen; show this one after it ended"
        case .invalidated(let reason):
            return "the ad ended before it was shown (\(reason))"
        case .notLoaded:
            return "the ad is not loaded yet; call load() first"
        case .containerTooSmall(let minimum):
            return "the view is too small for the ad; at least \(Int(minimum.width))×\(Int(minimum.height)) points are needed"
        case .presenterUnavailable:
            return "no view controller can present the ad now"
        case .wrongPresentation:
            return "this call does not fit the ad's format (show(in:) for overlay and pause, show() for linear; dismiss() only for overlay and pause)"
        }
    }

    public var errorDescription: String? { description }
}
