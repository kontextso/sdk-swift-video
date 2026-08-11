import Foundation

/// Ad lifecycle events delivered via `VideoSessionOptions.onEvent`
/// on the main thread.
///
/// The event set is an early sketch and will grow (viewability, video
/// quartiles, reward, …) as the formats are implemented.
public enum VideoAdEvent: Sendable {
    /// An ad for the given format was preloaded and is ready to show.
    case filled(AdData)
    /// No ad is available for the given format on this video.
    case noFill(AdData)
    /// An ad became visible to the user.
    case shown(AdData)
    /// The user tapped/clicked an ad.
    case clicked(AdData)
    /// Something went wrong (network, rendering, …).
    case error(ErrorData)

    public struct AdData: Sendable {
        public let format: VideoAdFormat
        /// The publisher's video ID the ad belongs to.
        public let externalId: String
    }

    public struct ErrorData: Sendable {
        public let externalId: String?
        public let message: String
    }
}
