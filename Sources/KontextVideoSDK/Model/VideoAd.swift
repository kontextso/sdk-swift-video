import Foundation

/// One ad returned by `/instream/preload`, ready to render. Same shape as the
/// ad server's `InstreamOverlayAdJson` (decoded from snake_case) plus the
/// trigger, placement and playback blocks.
public struct VideoAd: Sendable, Decodable {
    public let format: VideoAdFormat
    /// Unique per served ad — the wire's `bid_id`. Matches the `adId` on
    /// every later event for this ad.
    public let adId: String
    /// Stable id of the creative behind the ad, when the server sends one.
    public let creativeId: String?
    /// What this ad pays, in USD per 1,000 impressions. Known before the ad
    /// is shown, so the app can rank it against its other demand.
    public let ecpm: Double
    public let trigger: Trigger
    public let placement: Placement?
    public let playback: Playback?
    public let creative: VideoAdCreative
    public let tracking: VideoAdTracking

    enum CodingKeys: String, CodingKey {
        case format, creativeId, ecpm, trigger, placement, playback, creative, tracking
        case adId = "bidId"
    }

    /// All times are seconds (`TimeInterval`), like everywhere in the
    /// public API; the wire carries milliseconds (`from_ms`, `delay_ms`).
    public struct Trigger: Sendable, Decodable {
        /// `pause`, `range` (a window in content time), or `manual` (the
        /// app decides the moment — every interstitial, and overlays when
        /// the publisher shared no content to derive windows from).
        public let kind: String
        /// Window start / end in content time, `range` triggers only.
        public let from: TimeInterval?
        public let to: TimeInterval?
        /// Optional wait after the trigger before showing. Absent or 0 =
        /// show immediately, which is the requirement; the server may set
        /// it per ad if a partner wants a grace period.
        public let delay: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case kind, fromMs, toMs, delayMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            from = try c.decodeIfPresent(Int.self, forKey: .fromMs).map { TimeInterval($0) / 1000 }
            to = try c.decodeIfPresent(Int.self, forKey: .toMs).map { TimeInterval($0) / 1000 }
            delay = try c.decodeIfPresent(Int.self, forKey: .delayMs).map { TimeInterval($0) / 1000 }
        }
    }

    public struct Placement: Sendable, Decodable {
        /// Server's preferred edge for a banner; the app may override.
        public let position: String?
    }

    /// Video formats only. Times in seconds; the wire carries `skip_after_ms`.
    public struct Playback: Sendable, Decodable {
        /// The ad may be closed after this long, in seconds. `nil` = not
        /// closable; it ends only when the video completes.
        public let skipAfter: TimeInterval?
        public let muted: Bool?

        enum CodingKeys: String, CodingKey {
            case skipAfterMs, muted
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            skipAfter = try c.decodeIfPresent(Int.self, forKey: .skipAfterMs).map { TimeInterval($0) / 1000 }
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted)
        }
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
        /// Seconds; the wire carries `duration_ms`.
        public let duration: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case url, mimeType, w, h, durationMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            w = try c.decode(Int.self, forKey: .w)
            h = try c.decode(Int.self, forKey: .h)
            duration = try c.decodeIfPresent(Int.self, forKey: .durationMs).map { TimeInterval($0) / 1000 }
        }
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
