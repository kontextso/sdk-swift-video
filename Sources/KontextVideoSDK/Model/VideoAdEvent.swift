import Foundation

/// Ad lifecycle events delivered via `VideoSessionOptions.onEvent`
/// on the main thread.
public enum VideoAdEvent: Sendable {
    /// A `load(formats:)` finished: the server answered, and this is what
    /// is ready — one result row per requested format. An empty `slots`
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
        /// The served ad's bid ID — unique per served ad, so two `shown`
        /// events with different bid IDs are two different ads.
        public let bidId: String
    }

    public struct LoadedData: Sendable {
        public let videoId: String
        /// One row per requested format.
        public let results: [FormatResult]

        public struct FormatResult: Sendable {
            public let format: VideoAdFormat
            /// The ads this load appended to the placement's queue, in
            /// order. Empty = no fill.
            public let slots: [Slot]
            /// Why the server served less than it could have
            /// (`no_ad_match`, `frequency_capped`, `content_unsafe`, …).
            public let noFillReason: String?

            /// One served ad. Carries the bid id today; may grow.
            public struct Slot: Sendable {
                /// The served ad's bid id — matches later `shown` /
                /// `clicked` events and the placement's `pending` entries.
                public let id: String
            }
        }
    }

    public struct ErrorData: Sendable {
        public let videoId: String?
        public let message: String
    }
}
