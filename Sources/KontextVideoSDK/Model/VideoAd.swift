import Foundation

/// One ad returned by `/preload`, ready to render. The ad server derives it
/// from the DSP's VAST 4.2 `<NonLinearAds>` response (IAB CTV Ad Portfolio
/// pause ad); the SDK never sees the XML.
public struct VideoAd: Sendable, Decodable {
    public let format: VideoAdFormat
    /// Unique per served ad (one bid = one opportunity).
    public let bidId: String
    /// Stable id of the creative behind the bid, when the server sends one.
    public let creativeId: String?
    public let creative: VideoAdCreative
    public let tracking: VideoAdTracking
}

/// Render-ready creative: the static image and where a tap goes.
public struct VideoAdCreative: Sendable, Decodable {
    public struct Image: Sendable, Decodable {
        public let url: String
        public let mimeType: String?
        public let w: Int
        public let h: Int
    }

    public let image: Image
    public let clickThroughUrl: String?
}

/// Tracking URLs from the VAST, grouped by event. Fired by the SDK, not the
/// app: `impression` + `creativeView` on show, `click` on tap,
/// `overlayViewDuration` + `close` on hide.
public struct VideoAdTracking: Sendable, Decodable {
    public let impression: [String]
    public let click: [String]
    public let creativeView: [String]
    public let overlayViewDuration: [String]
    public let close: [String]
}
