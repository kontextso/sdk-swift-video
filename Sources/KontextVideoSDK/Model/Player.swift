import UIKit

/// The app's video player, as the SDK sees it. The app's own player object conforms, once; the SDK reads
/// what it needs when it needs it (building a request, firing `[CONTENTPLAYHEAD]`, measuring the box
/// at `show`). This is Google IMA's model: `IMAAdDisplayContainer` fills the container view's bounds and
/// `IMAContentPlayhead` is one property, `currentTime: TimeInterval`.
///
/// The protocol is the stable surface; the SDK can add an `AVPlayer` adapter and observe seeks, resizes
/// and Picture in Picture later without changing what the app implements. The SDK holds the player
/// weakly: it is usually the view controller that owns the `VideoAds`.
@MainActor
public protocol KontextVideoPlayer: AnyObject {
    /// The view the content plays in. Overlay and pause ads are placed in it; the SDK reads its bounds,
    /// window and full-screen state itself.
    var view: UIView { get }
    /// Content time, in seconds.
    var playhead: TimeInterval { get }
}

/// What an ads request says about the player, read from the protocol at request time.
struct PlayerSnapshot: Encodable, Sendable, Equatable {
    let width: Int
    let height: Int
    let fullscreen: Bool
    /// Milliseconds in content time; `nil` means the start of the video.
    let playhead: Int?

    /// `started` is `VideoAds.start()`: before it, the player's playhead belongs to other content and
    /// the request is a prefetch at content time 0.
    @MainActor
    static func read(from player: any KontextVideoPlayer, started: Bool) -> PlayerSnapshot {
        let bounds = player.view.bounds
        let screen = player.view.window?.bounds ?? UIScreen.main.bounds
        return PlayerSnapshot(
            width: Int(bounds.width.rounded()),
            height: Int(bounds.height.rounded()),
            fullscreen: bounds.width >= screen.width - 1 && bounds.height >= screen.height - 1,
            playhead: started ? Int((player.playhead * 1000).rounded()) : nil
        )
    }
}
