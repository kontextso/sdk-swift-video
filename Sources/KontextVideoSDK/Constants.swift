import Foundation

/// SDK-wide defaults. Mirrors the conventions of `sdk-swift`'s Constants.
public enum Constants {
    /// Production ad-server base URL.
    public static let defaultAdServerURL = URL(string: "https://server.megabrain.co")!

    /// `/preload` request timeout, in seconds.
    static let preloadTimeout: TimeInterval = 16
}
