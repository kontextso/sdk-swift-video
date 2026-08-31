import Foundation

/// Ad lifecycle events delivered via `VideoSessionOptions.onEvent`
/// on the main thread.
public enum VideoAdEvent: Sendable {
    /// An ad for the given format was preloaded and is ready to show.
    case filled(AdData)
    /// No ad is available for the given format on this video.
    case noFill(NoFillData)
    /// An ad became visible to the user.
    case shown(AdData)
    /// The user tapped/clicked an ad.
    case clicked(AdData)
    /// The user dismissed the ad before it ended (fullscreen Resume, or the
    /// app hid a swipe ad after the user swiped). The ad is already hidden.
    case closed(AdData)
    /// A video ad played to the end. The ad is already hidden.
    case completed(AdData)
    /// Something went wrong (network, rendering, …).
    case error(ErrorData)

    public struct AdData: Sendable {
        public let format: VideoAdFormat
        /// The publisher's unique video ID the ad belongs to.
        public let videoId: String
        /// The served ad's bid ID — unique per served ad, so two `shown`
        /// events with different bid IDs are two different ads.
        public let bidId: String
    }

    public struct NoFillData: Sendable {
        public let format: VideoAdFormat
        public let videoId: String
        /// The server's `no_fill_reason` (e.g. `no_ad_match`,
        /// `content_unsafe`), when it sent one.
        public let reason: String?
    }

    public struct ErrorData: Sendable {
        public let videoId: String?
        public let message: String
    }
}
