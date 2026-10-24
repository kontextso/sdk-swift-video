import Foundation

extension VideoAd {
    /// An ad as the server sent it, before rendering, as the SDK keeps it: the facts `Bid` and `VideoAd`
    /// report (times in seconds, whatever the wire sends), what the renderer needs, and the clocks. Built
    /// once from the wire object; the only place that reads `AdPayload`.
    struct ReceivedAd {
        let id: String
        let format: AdFormat
        let price: Price
        /// `nil` for a linear ad.
        let position: Position?
        /// Every size the creative was built for, the default first; the SDK picks one at `show`.
        let sizes: [Size]
        /// The default variant.
        var size: Size? { sizes.first }
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
        /// `ReceivedAd.now` at the first receipt: `expires` counts from here; a re-serve does not move it. Never a `Date`: the monotonic
        /// clock cannot be set by the user, so a changed device clock cannot expire an ad early or late.
        let receivedAt: TimeInterval
        /// Seconds the ad lives from receipt.
        let lifetime: TimeInterval

        init(ad: AdPayload, receivedAt: TimeInterval) {
            id = ad.id
            format = ad.format
            price = Price(value: ad.price.value, currency: ad.price.currency, precision: ad.price.precision == .exact ? .exact : .estimated)
            self.receivedAt = receivedAt
            lifetime = TimeInterval(ad.expires) / 1000
            creative = ad.creative
            switch ad.rendering {
            case .frame(let url): frameURL = url
            }
            tracking = ad.tracking
            switch ad.details {
            case .overlay(let wirePosition, let wireSizes, let wireDuration):
                switch wirePosition {
                case .top: position = .top
                case .bottom: position = .bottom
                }
                sizes = wireSizes.map { Size(width: $0.width, height: $0.height) }
                duration = wireDuration.map { TimeInterval($0) / 1000 }
                skipOffset = nil
            case .pause(let wirePosition, let wireSizes):
                sizes = wireSizes.map { Size(width: $0.width, height: $0.height) }
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
            Self.now - receivedAt >= lifetime
        }

        /// Seconds on a monotonic clock that keeps counting while the device sleeps (`CLOCK_MONOTONIC` on
        /// Apple platforms; `systemUptime` stops during sleep, and a bid must expire in a locked pocket too).
        static var now: TimeInterval {
            TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        }
    }
}
