import Foundation

/// One ad returned by `/instream/preload`, ready to render. Same shape as the
/// ad server's `InstreamOverlayAdJson` (decoded from snake_case) plus the
/// trigger, placement and playback blocks.
public struct VideoAd: Sendable, Decodable {
    public let format: VideoAdFormat
    /// Unique per served ad (one bid = one opportunity).
    public let bidId: String
    /// Stable id of the creative behind the bid, when the server sends one.
    public let creativeId: String?
    public let trigger: Trigger
    public let placement: Placement?
    public let playback: Playback?
    public let creative: VideoAdCreative
    public let tracking: VideoAdTracking

    public struct Trigger: Sendable, Decodable {
        /// `pause`, `swipe`, `range` (a window in content time), or
        /// `manual` (the app decides the moment — served when the
        /// publisher shared no content to derive windows from).
        public let kind: String
        /// Window start / end in content time, `range` triggers only.
        public let fromMs: Int?
        public let toMs: Int?
        /// Optional wait after the trigger before showing. Absent or 0 =
        /// show immediately, which is the requirement; the server may set
        /// it per ad if a partner wants a grace period.
        public let delayMs: Int?
    }

    public struct Placement: Sendable, Decodable {
        /// Server's preferred edge for a banner; the app may override.
        public let position: String?
    }

    /// Video formats only.
    public struct Playback: Sendable, Decodable {
        /// The ad may be skipped (swiped away) after this long. `nil` = not
        /// skippable; the app must wait for completion.
        public let skipAfterMs: Int?
        public let muted: Bool?
    }
}

/// Render-ready creative. Image formats carry `image`; video formats carry
/// `video`. Copy is written asynchronously on the server, so `headline` /
/// `body` may be absent.
public struct VideoAdCreative: Sendable, Decodable {
    public struct Image: Sendable, Decodable {
        public let url: String
        public let w: Int
        public let h: Int
    }

    public struct Video: Sendable, Decodable {
        public let url: String
        public let mimeType: String?
        public let w: Int
        public let h: Int
        public let durationMs: Int?
    }

    public struct CTA: Sendable, Decodable {
        public let text: String
        public let mode: String
        /// `/impression/{bid}/redirect` — records the click, then forwards.
        public let url: String
    }

    public struct Advertiser: Sendable, Decodable {
        public let name: String
        public let logoUrl: String?
    }

    public let image: Image?
    public let video: Video?
    public let headline: String?
    public let body: String?
    public let cta: CTA?
    public let advertiser: Advertiser?
}

/// The ad server's `TrackingUrls` — one URL per event, fired by the SDK.
/// `[CACHEBUSTING]` is substituted per fire; each URL fires at most once.
public struct VideoAdTracking: Sendable, Decodable {
    public let impression: String
    public let viewable: String
    public let notViewable: String
    public let viewUndetermined: String
    public let creativeView: String
    public let close: String
    public let overlayViewDuration: String
    /// Navigation target, not a pixel: opens the advertiser via the server.
    public let clickThrough: String
    public let clickTracking: String
    /// VAST linear events, video formats only (`/impression/{bid}/vast?event=`).
    public let video: Video?

    public struct Video: Sendable, Decodable {
        public let start: String
        public let firstQuartile: String
        public let midpoint: String
        public let thirdQuartile: String
        public let complete: String
        public let skip: String
        public let mute: String?
        public let unmute: String?
    }
}
