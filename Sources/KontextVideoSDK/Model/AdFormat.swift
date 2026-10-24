import Foundation

/// The three ad formats. Every request asks for all of them; `ads.format(_:)` returns one.
public enum AdFormat: String, Codable, Sendable, CaseIterable {
    /// A strip across the player while the content plays.
    case overlay
    /// A card, or the full player, while the content is paused.
    case pause
    /// A full-screen video at a moment the app picks.
    case linear
}
