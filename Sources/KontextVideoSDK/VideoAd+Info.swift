import Foundation

extension VideoAd {
    /// The facts of an ad, as the app sees them before and after rendering: what a `Bid` gives
    /// and what the `VideoAd` reports. Times are seconds, whatever the wire sends.
    public struct Info: Sendable, Equatable {
        public let id: String
        public let format: AdFormat
        public let price: Price
        /// `nil` for a linear ad.
        public let position: Position?
        /// Every size the creative was built for, the default first; the SDK picks one at `show`.
        public let sizes: [Size]
        /// The default variant; `VideoAd.size` reports the one chosen at `show` instead.
        public var size: Size? { sizes.first }
        /// A linear ad's video length, or how long an overlay stays on screen; `nil` for a pause ad and
        /// for an overlay that stays until the app ends it.
        public let duration: TimeInterval?
        /// When a linear ad's Close may appear; `nil` means not before the end.
        public let skipOffset: TimeInterval?
        /// On a rewarded linear ad.
        public let reward: Reward?
    }

    /// An ad as the server sent it, before rendering, as the SDK keeps it: the public `info`, what the renderer
    /// needs, and the clocks. Built once from the wire object; the only place that reads `AdPayload`.
    struct ReceivedAd {
        let info: Info
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
            creative = ad.creative
            switch ad.rendering {
            case .frame(let url): frameURL = url
            }
            tracking = ad.tracking
            let price = Price(value: ad.price.value, currency: ad.price.currency, precision: ad.price.precision == .exact ? .exact : .estimated)
            let position: Position?
            let sizes: [Size]
            let duration: TimeInterval?
            let skipOffset: TimeInterval?
            let reward: Reward?
            switch ad.details {
            case .overlay(let wirePosition, let wireSizes, let wireDuration):
                switch wirePosition {
                case .top: position = .top
                case .bottom: position = .bottom
                }
                sizes = wireSizes.map { Size(width: $0.width, height: $0.height) }
                duration = wireDuration.map { TimeInterval($0) / 1000 }
                skipOffset = nil
                reward = nil
            case .pause(let wirePosition, let wireSizes):
                sizes = wireSizes.map { Size(width: $0.width, height: $0.height) }
                switch wirePosition {
                case .top: position = .top
                case .bottom: position = .bottom
                case .fullscreen: position = .fullscreen
                }
                duration = nil
                skipOffset = nil
                reward = nil
            case .linear(let wireDuration, let wireSkipOffset, let wireReward):
                position = nil
                sizes = []
                duration = TimeInterval(wireDuration) / 1000
                skipOffset = wireSkipOffset.map { TimeInterval($0) / 1000 }
                reward = wireReward.map { Reward(label: $0.label, amount: $0.amount) }
            }
            info = Info(id: ad.id, format: ad.format, price: price, position: position, sizes: sizes, duration: duration, skipOffset: skipOffset, reward: reward)
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
