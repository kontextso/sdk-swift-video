import Foundation

/// One ad returned by `/instream/preload`, ready to render. Same shape as the
/// ad server's `InstreamOverlayAdJson` (decoded from snake_case) plus the
/// pause trigger and placement.
public struct VideoAd: Sendable, Decodable {
    public let format: VideoAdFormat
    /// Unique per served ad (one bid = one opportunity).
    public let bidId: String
    /// Stable id of the creative behind the bid, when the server sends one.
    public let creativeId: String?
    public let trigger: Trigger
    public let placement: Placement
    public let creative: VideoAdCreative
    public let tracking: VideoAdTracking

    public struct Trigger: Sendable, Decodable {
        public let kind: String
        /// Wait this long after the pause before showing, so an accidental
        /// tap that resumes immediately never surfaces the ad. Server
        /// default 2000.
        public let delayMs: Int?
    }

    public struct Placement: Sendable, Decodable {
        /// Server's preferred edge for the banner; the app may override.
        public let position: String?
    }
}

/// Render-ready creative. Copy is written asynchronously on the server, so
/// `headline` / `body` may be absent; the image and click-through never are.
public struct VideoAdCreative: Sendable, Decodable {
    public struct Image: Sendable, Decodable {
        public let url: String
        public let w: Int
        public let h: Int
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

    public let image: Image
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
}
