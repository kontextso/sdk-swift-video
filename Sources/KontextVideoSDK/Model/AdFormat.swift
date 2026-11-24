/// The three ad formats. Every request asks for all of them; the answer carries the formats the publisher configured
/// for the `VideoAds`'s `page`, and `ads.format(_:)` returns one. Top level on
/// purpose, the one public type not nested under `KontextVideo` or `VideoAd`: it names the formats
/// everywhere, and an app type of this name is not a realistic collision.
public enum AdFormat: String, Sendable, CaseIterable {
    /// A strip across the player while the content plays.
    case overlay
    /// Over the player while the content is paused: a card over its top or bottom, or the whole player with
    /// Resume and ✕ of its own. The server decides which (`VideoAd.position`); `show(in:)` shows either.
    case pause
    /// A full-screen video at a moment the app picks.
    case linear
}
