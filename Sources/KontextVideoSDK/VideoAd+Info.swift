import Foundation

extension VideoAd {
    /// The ad as the SDK knows it, built once from the wire object; the only place that reads `AdPayload`.
    /// `Bid` and `VideoAd` both forward the public part, in seconds whatever the wire sends; the rest is
    /// what the renderer needs.
    struct Info {
        let id: String
        let placementId: String
        let format: AdFormat
        let price: Price
        let position: Position?
        let sizes: [Size]
        /// The default variant; `VideoAd` reports the one chosen at `show` instead.
        var size: Size? { sizes.first }
        let duration: TimeInterval?
        let skipOffset: TimeInterval?
        let reward: Reward?
        /// What the page renders; decides the viewability clock, the video events and the error codes.
        let creative: AdPayload.Creative
        /// The frame page to show in the WebView.
        let frameURL: URL
        /// The beacons; the SDK fires each once.
        let tracking: [AdPayload.TrackingEvent]
        /// `ProcessInfo.systemUptime` at receipt: `expires` counts from here. Never a `Date`: the monotonic
        /// clock cannot be set by the user, so a changed device clock cannot expire an ad early or late.
        let receivedAt: TimeInterval
        /// Seconds the ad lives from receipt.
        let lifetime: TimeInterval

        init(ad: AdPayload, receivedAt: TimeInterval) {
            self.receivedAt = receivedAt
            lifetime = TimeInterval(ad.expires) / 1000
            id = ad.id
            placementId = ad.placementId
            format = ad.format
            price = Price(value: ad.price.value, currency: ad.price.currency, precision: ad.price.precision == .exact ? .exact : .estimated)
            creative = ad.creative
            switch ad.rendering {
            case .frame(let url): frameURL = url
            }
            tracking = ad.tracking
            switch ad.details {
            case .overlay(let position, let sizes, let duration):
                switch position {
                case .top: self.position = .top
                case .bottom: self.position = .bottom
                }
                self.sizes = sizes.map { Size(width: $0.width, height: $0.height) }
                self.duration = duration.map { TimeInterval($0) / 1000 }
                skipOffset = nil
                reward = nil
            case .pause(let position, let sizes):
                self.sizes = sizes.map { Size(width: $0.width, height: $0.height) }
                switch position {
                case .top: self.position = .top
                case .bottom: self.position = .bottom
                case .fullscreen: self.position = .fullscreen
                }
                duration = nil
                skipOffset = nil
                reward = nil
            case .linear(let duration, let skipOffset, let reward):
                position = nil
                sizes = []
                self.duration = TimeInterval(duration) / 1000
                self.skipOffset = skipOffset.map { TimeInterval($0) / 1000 }
                self.reward = reward.map { Reward(label: $0.label, amount: $0.amount) }
            }
        }

        var isExpired: Bool {
            ProcessInfo.processInfo.systemUptime - receivedAt >= lifetime
        }

        /// Seconds of life left, for the expiry timer.
        var remainingLifetime: TimeInterval {
            max(0, lifetime - (ProcessInfo.processInfo.systemUptime - receivedAt))
        }
    }
}
