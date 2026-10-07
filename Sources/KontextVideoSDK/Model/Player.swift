// TODO: temporary. Player will become a handle to the app's actual player, from which the SDK reads
// the size, fullscreen state and playhead itself; for now the app sets and updates the values.
/// Represents the app's video player: the area the ads will be shown in, in points, whether it is
/// full screen, and where the content is. For a prefetch before the player exists, pass the size it
/// will most likely have.
@MainActor
public final class Player {
    public var width: Int
    public var height: Int
    public var fullscreen: Bool
    /// Milliseconds in content time; `nil` means the start of the video.
    public var playhead: Int?

    public init(width: Int, height: Int, fullscreen: Bool, playhead: Int? = nil) {
        self.width = width
        self.height = height
        self.fullscreen = fullscreen
        self.playhead = playhead
    }

    /// The values as the request sends them.
    var snapshot: PlayerSnapshot {
        PlayerSnapshot(width: width, height: height, fullscreen: fullscreen, playhead: playhead)
    }
}

struct PlayerSnapshot: Encodable, Sendable, Equatable {
    let width: Int
    let height: Int
    let fullscreen: Bool
    let playhead: Int?
}
