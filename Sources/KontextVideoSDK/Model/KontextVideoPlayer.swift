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
