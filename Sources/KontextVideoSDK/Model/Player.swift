// TODO: temporary. Player will become a handle to the app's actual player, from which the SDK reads
// the size, fullscreen state and playhead itself; for now the app passes and updates the values.
/// The area the ads will be shown in, in points, and where the content is.
/// For a prefetch before the player exists, pass the size it will most likely have.
public struct Player: Encodable, Sendable, Equatable {
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
}
