/// The three ad formats. Every request asks for all of them; `ads.format(_:)` returns one. Top level on
/// purpose, the one public type not nested under `KontextVideo` or `VideoAd`: it names the formats
/// everywhere, and an app type of this name is not a realistic collision.
public enum AdFormat: String, Codable, Sendable, CaseIterable {
    /// A strip across the player while the content plays.
    case overlay
    /// A card, or the full player, while the content is paused.
    case pause
    /// A full-screen video at a moment the app picks.
    case linear
}
