import AVFoundation
import AVKit
import UIKit

extension KontextVideo {
    /// `KontextVideoPlayer` for an `AVPlayer`, so most apps write no conformance of their own (IMA's
    /// `IMAAVPlayerContentPlayhead` plays the same role). The playhead is the player's current time; the
    /// view is where the content plays and where overlay and pause ads go.
    ///
    /// Keep the adapter alive as long as the player screen: the SDK holds it weakly.
    @MainActor
    public final class AVPlayerAdapter: KontextVideoPlayer {
        public let player: AVPlayer
        public let view: UIView

        /// `view`: the view the content plays in, usually the one holding the `AVPlayerLayer`.
        public init(player: AVPlayer, view: UIView) {
            self.player = player
            self.view = view
        }

        /// For `AVPlayerViewController`: ads go into its `contentOverlayView`, over the video and under
        /// the transport controls, which is exactly where Apple puts content of this kind.
        public convenience init(playerViewController: AVPlayerViewController) {
            let player = playerViewController.player ?? AVPlayer()
            self.init(player: player, view: playerViewController.contentOverlayView ?? playerViewController.view)
        }

        /// Content time in seconds; 0 while the player has no item or an indefinite time.
        public var playhead: TimeInterval {
            let time = player.currentTime()
            guard time.isNumeric, !time.seconds.isNaN else { return 0 }
            return max(0, time.seconds)
        }
    }
}
