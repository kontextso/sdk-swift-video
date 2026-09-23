import Foundation

/// SDK-wide defaults. Mirrors the conventions of `sdk-swift`'s Constants.
public enum Constants {
    /// Production ad-server base URL.
    public static let defaultAdServerURL = URL(string: "https://server.megabrain.co")!

    /// `/preload` request timeout, in seconds. May be overridden by the
    /// `/init` response.
    static let defaultPreloadTimeout: TimeInterval = 16

    /// `/init` request timeout, in seconds.
    static let initTimeout: TimeInterval = 16

    /// How long an interstitial's video has to produce its first frame
    /// before the SDK gives up (bad URL, dead CDN, endless buffering) and
    /// reports failure so the app is never stuck on a blank screen.
    static let interstitialStartTimeout: TimeInterval = 8

    /// How long a mid-playback stall may last before the SDK reports
    /// failure. A stall that recovers within this window is ignored.
    static let interstitialStallTimeout: TimeInterval = 8

    /// How long an ad view stays in the hierarchy after `destroy()` when
    /// it was on screen. Open Measurement needs the view alive for about a
    /// second after the session is finished so its script can send the
    /// final beacons; the same grace applies to tracking pings.
    static let teardownDelay: TimeInterval = 1
}
