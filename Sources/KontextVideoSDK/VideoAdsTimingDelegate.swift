import Foundation

/// Timed mode: the SDK watches the content playhead and tells the app when a load for a placement makes
/// sense. It never loads by itself. Set it as `ads.timingDelegate`; held weakly.
///
/// The window of a loaded ad opening is the ad's own moment, delivered on its `VideoAdDelegate` as
/// `videoAdDidReachWindow`.
@MainActor
public protocol VideoAdsTimingDelegate: AnyObject {
    /// A load for this placement makes sense now: the server's `nextRequestAt` came, the viewer seeked
    /// (the pending ads chosen for the old content time were discarded), or a pending ad was discarded.
    func videoAds(_ ads: VideoAds, didRequestLoadOf placementId: String, reason: VideoAds.LoadReason)
}

public extension VideoAdsTimingDelegate {
    func videoAds(_ ads: VideoAds, didRequestLoadOf placementId: String, reason: VideoAds.LoadReason) {}
}

extension VideoAds {
    /// Why the SDK suggests a load.
    public enum LoadReason: Sendable, Equatable {
        /// The playhead reached the content time the server named for the placement's next request.
        case nextRequestReached
        /// The viewer seeked; the placement's pending ad, if any, was discarded (`didInvalidate(.seeked)`).
        case seeked
        /// A pending ad of the placement was discarded for this reason.
        case adDiscarded(VideoAd.InvalidationReason)
    }
}
