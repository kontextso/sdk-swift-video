/// The four ad formats. Every request asks for all of them; `ads.format(_:)` returns one. Top level on
/// purpose, the one public type not nested under `KontextVideo` or `VideoAd`: it names the formats
/// everywhere, and an app type of this name is not a realistic collision.
public enum AdFormat: String, Sendable, CaseIterable {
    /// A strip across the player while the content plays.
    case overlay
    /// A card over the top or the bottom of the player while the content is paused.
    case pause
    /// The whole player while the content is paused, with Resume and ✕ of its own.
    case pauseFullscreen
    /// A full-screen video at a moment the app picks.
    case linear
}
