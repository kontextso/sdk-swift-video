import Foundation

/// SDK-wide defaults. Mirrors the conventions of `sdk-swift`'s Constants.
public enum Constants {
    /// Production ad-server base URL.
    public static let defaultAdServerURL = URL(string: "https://server.megabrain.co")!

    /// `/preload` request timeout, in seconds.
    static let preloadTimeout: TimeInterval = 16

    /// How long an ad view stays in the hierarchy after `destroy()` when
    /// it was on screen. Open Measurement needs the view alive for about a
    /// second after the session is finished so its script can send the
    /// final beacons; the same grace applies to tracking pings.
    static let teardownDelay: TimeInterval = 1
}
