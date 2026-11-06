import Combine
import Foundation

/// Your player, as the SDK reads it: where the content is, and whether it plays. Pass it to
/// `VideoAds.track(_:)`; an `AVPlayer` needs no conformance, `track` takes it directly. The SDK holds it
/// strongly until `destroy()` or the next `track`, so a small wrapper around your player needs no other
/// reference; it reads it on the main actor. A conforming type that references the `VideoAds`, or the object
/// owning it, keeps both alive until `destroy()`: call `destroy()` then, or do not reference the ads from it.
@MainActor
public protocol ContentPlayer: AnyObject {
    /// Where the content is, in seconds of the episode.
    var currentTime: TimeInterval { get }
    /// `false` when the viewer or your app paused the content, or it ended. Buffering and seeking count as
    /// playing: the content is about to move on.
    var isPlaying: Bool { get }
    /// Optional: emits whenever `isPlaying` changes, for an immediate reaction. Without it the SDK reads
    /// `isPlaying` four times a second while an overlay or pause ad is on screen, and at every `show`.
    /// Declare it with exactly this type, `AnyPublisher<Bool, Never>?`: a property of another type (not
    /// optional, an `@Published` projection) is not this requirement, and the SDK falls back to reading
    /// `isPlaying`, saying so once on the console.
    var isPlayingPublisher: AnyPublisher<Bool, Never>? { get }
    /// Optional: the playback speed (1 is normal), when the player knows it. An overlay's `duration` counts
    /// seconds of video, and the speed tells fast playback from a seek. `nil` (the default) allows up to
    /// about 4×; a value that is not finite reads as `nil`.
    var playbackSpeed: Double? { get }
    /// Optional: emits at each seek (the position jumped): an overlay's count of seconds of video goes on
    /// from the new position. Without it a seek is told from the position alone, so a small one can count.
    var seekPublisher: AnyPublisher<Void, Never>? { get }
    /// Optional: emits when the player moves to another item (another episode, a looper's next loop): an overlay
    /// or pause ad over it ends as `.interrupted`. Not at the end of an item: `isPlaying` turning false tells
    /// that, as it does for an `AVPlayer`, and a pause ad over ended content stays. Without it the SDK learns
    /// only from `isPlaying` and `currentItem`.
    var contentChangedPublisher: AnyPublisher<Void, Never>? { get }
    /// Optional: a value that stands for the episode playing (an id, a URL), compared with `==`; give a new one
    /// for each loop of a looped episode. An overlay or pause ad of a `VideoAds` throws
    /// `invalidated(.contentChanged)` at `show` once it differs from the item at `track`. Without it only the
    /// player moving to another `VideoAds` is seen.
    var currentItem: AnyHashable? { get }
}

/// The defaults of the optional members: the SDK does without, and says so once on the console, so a member
/// declared with another type, which the compiler takes for a different property, does not go unnoticed.
extension ContentPlayer {
    /// No publisher: the SDK reads `isPlaying` when it needs it.
    public var isPlayingPublisher: AnyPublisher<Bool, Never>? {
        PlayerFallback.note("isPlayingPublisher", of: Self.self, level: .warning,
                            "the SDK reads isPlaying four times a second while an ad is on screen; declare it as AnyPublisher<Bool, Never>? to be heard at once")
        return nil
    }

    /// No speed: up to about 4× counts as playback.
    public var playbackSpeed: Double? {
        PlayerFallback.note("playbackSpeed", of: Self.self, level: .info, "a step up to about 4× counts as playback; declare it as Double? to give the speed")
        return nil
    }

    /// No seeks reported: they are told from the position.
    public var seekPublisher: AnyPublisher<Void, Never>? {
        PlayerFallback.note("seekPublisher", of: Self.self, level: .info, "seeks are told from the position; declare it as AnyPublisher<Void, Never>? to report them")
        return nil
    }

    /// No item reported: only the player moving to another `VideoAds` tells another episode.
    public var currentItem: AnyHashable? {
        PlayerFallback.note("currentItem", of: Self.self, level: .info,
                            "another episode is told only by the player moving to another VideoAds; declare it as AnyHashable? to report it")
        return nil
    }

    /// No item changes reported: `isPlaying` tells the end.
    public var contentChangedPublisher: AnyPublisher<Void, Never>? {
        PlayerFallback.note("contentChangedPublisher", of: Self.self, level: .info,
                            "another item or the end is told from isPlaying only; declare it as AnyPublisher<Void, Never>? to report them")
        return nil
    }
}

/// Says once per process, per member, that a `ContentPlayer` left an optional member to its default.
@MainActor
enum PlayerFallback {
    /// The members already said. Tests empty it.
    static var noted: Set<String> = []

    static func note(_ member: String, of type: Any.Type, level: KontextVideo.Configuration.LogLevel, _ consequence: String) {
        guard noted.insert(member).inserted else { return }
        let message = "\(type) has no \(member) of the protocol's type, so the default is used: \(consequence)"
        if level == .warning { Logger.warning(message) } else { Logger.info(message) }
    }
}
