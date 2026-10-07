/// The area the ads will be shown in, in points, and where the content is.
/// For a prefetch before the player exists, pass the size it will most likely have.
public struct Player: Encodable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let fullscreen: Bool
    /// Milliseconds in content time; `nil` means the start of the video.
    public let playhead: Int?

    public init(width: Int, height: Int, fullscreen: Bool, playhead: Int? = nil) {
        self.width = width
        self.height = height
        self.fullscreen = fullscreen
        self.playhead = playhead
    }
}
