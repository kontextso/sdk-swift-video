import Foundation

/// Everything needed to make an ad, and not the ad: `AdPayload` (the wire) converted once into the facts
/// `VideoAd` reports (times in seconds, whatever the wire sends), what the renderer needs, and the clock.
/// A plain value with no behavior, as `UIFontDescriptor` is to `UIFont`. The only place that reads `AdPayload`.
struct AdDescriptor {
    let id: String
    let format: AdFormat
    let price: VideoAd.Price
    /// `nil` for a linear ad.
    let position: VideoAd.Position?
    /// Every size the creative was built for, the default first; the SDK picks one at `show`.
    let sizes: [VideoAd.Size]
    /// The default variant.
    var size: VideoAd.Size? { sizes.first }
    /// A linear ad's video length, or how long an overlay stays on screen; `nil` for a pause ad and
    /// for an overlay that stays until the app ends it.
    let duration: TimeInterval?
    /// When a linear ad's Close may appear; `nil` means not before the end.
    let skipOffset: TimeInterval?

    /// What the page renders; decides the viewability clock, the video events and the error codes.
    let creative: AdPayload.Creative
    /// The frame page to show in the WebView.
    let frameURL: URL
    /// The beacons; the SDK fires each once.
    let tracking: [AdPayload.TrackingEvent]
    /// The SKAdNetwork payload of an app-install ad; `nil` for every other ad.
    let skan: Skan?
    /// `Environment.now()` at the first receipt: `expires` counts from here; a re-serve does not move it.
    let receivedAt: TimeInterval
    /// Seconds the ad lives from receipt.
    let lifetime: TimeInterval

    init(payload ad: AdPayload, receivedAt: TimeInterval) {
        id = ad.id
        format = ad.format
        price = VideoAd.Price(value: ad.price.value, currency: ad.price.currency, precision: ad.price.precision == .exact ? .exact : .estimated)
        self.receivedAt = receivedAt
        lifetime = TimeInterval(ad.expires) / 1000
        creative = ad.creative
        switch ad.rendering {
        case .frame(let url): frameURL = url
        }
        tracking = ad.tracking
        skan = ad.attribution?.skan
        switch ad.details {
        case .overlay(let wirePosition, let wireSizes, let wireDuration):
            switch wirePosition {
            case .top: position = .top
            case .bottom: position = .bottom
            }
            sizes = wireSizes.map { VideoAd.Size(width: $0.width, height: $0.height, scalable: $0.scalable) }
            duration = wireDuration.map { TimeInterval($0) / 1000 }
            skipOffset = nil
        case .pause(let wirePosition, let wireSizes):
            sizes = wireSizes.map { VideoAd.Size(width: $0.width, height: $0.height, scalable: $0.scalable) }
            switch wirePosition {
            case .top: position = .top
            case .bottom: position = .bottom
            case .fullscreen: position = .fullscreen
            }
            duration = nil
            skipOffset = nil
        case .linear(let wireDuration, let wireSkipOffset):
            position = nil
            sizes = []
            duration = TimeInterval(wireDuration) / 1000
            skipOffset = wireSkipOffset.map { TimeInterval($0) / 1000 }
        }
    }

    var isExpired: Bool {
        Environment.now() - receivedAt >= lifetime
    }
}
