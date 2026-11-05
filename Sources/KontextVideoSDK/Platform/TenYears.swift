import Foundation

/// The longest span the SDK takes from a player, a page or the server: ten years. Beyond it a playhead, an offset
/// or a duration is nonsense, and near `Int.max` converting it to `Int` would trap. One value, in the two units
/// the SDK counts in.
enum TenYears {
    /// In seconds, as the SDK keeps time (a playhead, a `TimeInterval`).
    static let seconds: TimeInterval = 10 * 365 * 86_400
    /// The same span in milliseconds, as the wire counts (a duration, an offset).
    static let milliseconds: Double = seconds * 1000
}
