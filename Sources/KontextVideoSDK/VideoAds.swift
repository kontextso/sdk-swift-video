/// The ads of one video. Created with `KontextVideo.shared.createVideoAds(for:)`; any number can be
/// alive at once, for example the next episode's while the current one plays.
@MainActor
public final class VideoAds {
    public let video: Video
    /// The player box and playhead the requests describe. Update `playhead` as the content plays.
    // TODO: temporary, see Player.
    public var player: Player
    /// `true` after `destroy()`: the object does nothing any more.
    public private(set) var isDestroyed = false

    init(video: Video, player: Player) {
        self.video = video
        self.player = player
        Logger.debug("VideoAds created for video \(video.id)")
    }

    /// Releases the video's ads. Call it when the viewer leaves the video. Nothing destroys a
    /// `VideoAds` for you, so destroy the previous episode's when you move on.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        Logger.debug("VideoAds destroyed for video \(video.id)")
    }
}
