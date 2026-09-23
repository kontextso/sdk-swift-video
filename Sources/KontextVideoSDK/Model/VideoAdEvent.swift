import Foundation

/// Ad lifecycle events delivered via `VideoSessionOptions.onEvent`
/// on the main thread.
public enum VideoAdEvent: Sendable {
    /// A `load(formats:)` finished: the server answered, and this is what
    /// is ready — one result row per requested format. An empty `ads`
    /// with a `noFillReason` is the no-fill case.
    case loaded(LoadedData)
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
        /// Unique per served ad, so two `shown` events with different
        /// `adId`s are two different ads. Matches
        /// `loaded.results[].ads[].id`.
        public let adId: String
    }

    public struct LoadedData: Sendable {
        public let videoId: String
        /// One row per requested format.
        public let results: [FormatResult]

        public struct FormatResult: Sendable {
            public let format: VideoAdFormat
            /// The ads this load appended to the placement's queue, in
            /// order. Empty = no fill.
            public let ads: [Ad]
            /// Why the server served less than it could have
            /// (`no_ad_match`, `frequency_capped`, `content_unsafe`, …).
            public let noFillReason: String?

            /// One served ad.
            public struct Ad: Sendable {
                /// Unique per served ad — matches the `adId` on later
                /// `shown` / `clicked` events and the placement's
                /// `pending` entries.
                public let id: String
                /// USD per 1,000 impressions — the same value as
                /// `VideoAd.ecpm` on the placement's `pending` entry.
                public let ecpm: Double
            }
        }
    }

    public struct ErrorData: Sendable {
        public let videoId: String?
        public let message: String
    }
}
