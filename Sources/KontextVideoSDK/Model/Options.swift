import Foundation

public enum AdFormat: String, Codable, Sendable {
    /// A strip across the player while the content plays.
    case overlay
    /// A card, or the full player, while the content is paused.
    case pause
    /// A full-screen video at a moment the app picks.
    case linear
}

public enum AdPosition: String, Codable, Sendable {
    case top
    case bottom
}

public struct PauseOptions: Encodable, Sendable, Equatable, PlacementOptions {
    public enum Position: String, Codable, Sendable {
        case top
        case bottom
        case fullscreen
    }

    /// What the app can render; the default is top and bottom.
    public let positions: [Position]?

    public init(positions: [Position]? = nil) {
        self.positions = positions
    }

    public static let `default` = PauseOptions()
    public var formatOptions: FormatOptions { .pause(self) }
}

public struct OverlayOptions: Encodable, Sendable, Equatable, PlacementOptions {
    /// Where the app can render it; the default is top and bottom.
    public let positions: [AdPosition]?
    /// Seconds on screen at most; the server picks a creative whose `duration` fits. The SDK removes the
    /// overlay itself when its `duration` elapses.
    public let maxDuration: TimeInterval?

    public init(positions: [AdPosition]? = nil, maxDuration: TimeInterval? = nil) {
        self.positions = positions
        self.maxDuration = maxDuration
    }

    public static let `default` = OverlayOptions()
    public var formatOptions: FormatOptions { .overlay(self) }

    private enum CodingKeys: String, CodingKey {
        case positions, maxDuration
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(positions, forKey: .positions)
        try container.encodeIfPresent(maxDuration.map { Int(($0 * 1000).rounded()) }, forKey: .maxDuration)
    }
}

/// `timing` says where the app will show it, `maxDuration` caps the video, `muted` starts it with the
/// sound off, `rewarded` asks for a non-skippable video with a reward granted when it completes.
public struct LinearOptions: Encodable, Sendable, Equatable, PlacementOptions {
    public enum Timing: String, Encodable, Sendable {
        case preroll
        case midroll
        case postroll
    }

    /// Where the app will show it; the default is `midroll`.
    public let timing: Timing?
    /// Caps the video length, in seconds (milliseconds on the wire).
    public let maxDuration: TimeInterval?
    /// Start with the sound off; the default is `false`.
    public let muted: Bool?
    /// Only non-skippable demand; the reward is granted when the video completes.
    public let rewarded: Bool?

    public init(timing: Timing? = nil, maxDuration: TimeInterval? = nil, muted: Bool? = nil, rewarded: Bool? = nil) {
        self.timing = timing
        self.maxDuration = maxDuration
        self.muted = muted
        self.rewarded = rewarded
    }

    public static let `default` = LinearOptions()
    public var formatOptions: FormatOptions { .linear(self) }

    private enum CodingKeys: String, CodingKey {
        case timing, maxDuration, muted, rewarded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(timing, forKey: .timing)
        try container.encodeIfPresent(maxDuration.map { Int(($0 * 1000).rounded()) }, forKey: .maxDuration)
        try container.encodeIfPresent(muted, forKey: .muted)
        try container.encodeIfPresent(rewarded, forKey: .rewarded)
    }
}
