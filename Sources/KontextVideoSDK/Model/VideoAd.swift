import Foundation

/// One ad returned by `/preload`, ready to render.
public struct VideoAd: Sendable, Decodable {
    public let format: VideoAdFormat
    public let bidId: String
    public let creative: VideoAdCreative
}

/// Render-ready creative for a native ad view.
public struct VideoAdCreative: Sendable, Decodable {
    public struct Image: Sendable, Decodable {
        public let url: String
        public let w: Int
        public let h: Int
    }

    public struct CTA: Sendable, Decodable {
        public let text: String
        public let url: String
    }

    /// Advertiser/brand display name.
    public let advertiser: String?
    public let headline: String
    public let body: String
    public let image: Image
    public let cta: CTA
}
