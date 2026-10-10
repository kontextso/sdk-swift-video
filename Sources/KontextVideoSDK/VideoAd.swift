import Foundation

/// One ad, returned by a placement's `load`. The app owns it: keep a reference until it is shown, drop it
/// and it is gone (the placement only holds it weakly). An ad is shown at most once.
///
/// Read-only facts about the ad for the app's own decisions (an auction, a debug screen); times are
/// seconds and `expirationDate` is a `Date`, whatever the wire sends.
@MainActor
public final class VideoAd {
    public struct Price: Sendable, Equatable {
        public enum Precision: Sendable {
            /// A DSP's clearing price.
            case exact
            /// Our own or house demand, a forecast.
            case estimated
        }

        /// Per 1,000 impressions.
        public let value: Double
        /// ISO 4217.
        public let currency: String
        public let precision: Precision
    }

    /// The box the creative was built for, in points. The SDK scales it down to 50 % of this when the
    /// player is smaller, and refuses to show below that.
    public struct Size: Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    /// Where the server placed the ad, among the `positions` the app offered.
    public enum Position: Sendable, Equatable {
        case top
        case bottom
        case fullscreen
    }

    public enum Trigger: Sendable, Equatable {
        /// The app decides the moment.
        case manual
        /// Timed mode: show it between `from` and `to`, seconds in content time.
        case window(from: TimeInterval, to: TimeInterval)
    }

    /// What the viewer earns when a rewarded interstitial completes.
    public struct Reward: Sendable, Equatable {
        public let label: String
        public let amount: Double
    }

    /// Why a loaded ad can no longer be shown.
    public enum InvalidationReason: Sendable, Equatable {
        /// `expirationDate` passed before the ad was shown.
        case expired
        /// `user`, `regulatory` or `variantId` changed; the next load carries the new values.
        case targetingChanged
        /// The `VideoAds` was destroyed.
        case destroyed
    }

    public let id: String
    public let placementId: String
    public let format: AdFormat
    public let price: Price
    /// When the ad stops being showable. The server sends a relative lifetime; this is it as a `Date`, for
    /// the app's eyes. The SDK's own check runs on the monotonic clock, so a changed device clock cannot
    /// expire an ad early or late.
    public let expirationDate: Date
    /// `nil` for an interstitial.
    public let position: Position?
    /// `nil` for an interstitial and for a full-screen pause ad.
    public let size: Size?
    /// Overlay: how long it stays on screen. Interstitial: the video's length. Seconds; `nil` for a pause ad.
    public let duration: TimeInterval?
    /// Interstitial: seconds until the Close may appear; `nil` means no Close before the video completes.
    public let skipOffset: TimeInterval?
    /// Set on a rewarded interstitial.
    public let reward: Reward?
    public let trigger: Trigger

    /// Whether `show` can be called: loaded, not yet shown, not invalidated. A hint for "show or load"
    /// decisions, not the authority: the box is measured only at `show`, and `show` throws when it cannot
    /// begin. TODO(step 2): `true` once the creative reported `ad.loaded`.
    public var isReady: Bool {
        false
    }

    /// Why the ad was invalidated, once it was.
    public private(set) var invalidationReason: InvalidationReason?

    /// The wire object, for the steps that render and track it.
    let ad: Ad
    /// `ProcessInfo.systemUptime` at receipt: `expires` counts from here.
    let receivedAt: TimeInterval

    init(ad: Ad) {
        let now = ProcessInfo.processInfo.systemUptime
        let lifetime = TimeInterval(ad.expires) / 1000
        self.ad = ad
        self.receivedAt = now
        id = ad.id
        placementId = ad.placementId
        format = ad.format
        price = Price(value: ad.price.value, currency: ad.price.currency, precision: ad.price.precision == .exact ? .exact : .estimated)
        expirationDate = Date().addingTimeInterval(lifetime)
        switch ad.trigger {
        case .manual: trigger = .manual
        case .window(let from, let to): trigger = .window(from: TimeInterval(from) / 1000, to: TimeInterval(to) / 1000)
        }
        switch ad.details {
        case .overlay(let position, let size, let duration):
            self.position = position == .top ? .top : .bottom
            self.size = Size(width: size.width, height: size.height)
            self.duration = TimeInterval(duration) / 1000
            skipOffset = nil
            reward = nil
        case .pause(let position, let size):
            switch position {
            case .top: self.position = .top
            case .bottom: self.position = .bottom
            case .fullscreen: self.position = .fullscreen
            }
            self.size = size.map { Size(width: $0.width, height: $0.height) }
            duration = nil
            skipOffset = nil
            reward = nil
        case .interstitial(let duration, let skipOffset, let reward):
            position = nil
            size = nil
            self.duration = TimeInterval(duration) / 1000
            self.skipOffset = skipOffset.map { TimeInterval($0) / 1000 }
            self.reward = reward.map { Reward(label: $0.label, amount: $0.amount) }
        }
    }

    /// On the monotonic clock, as the SDK decides it.
    var isExpired: Bool {
        ProcessInfo.processInfo.systemUptime - receivedAt >= TimeInterval(ad.expires) / 1000
    }

    /// Whether this ad still counts for its placement's one-at-a-time rule.
    var occupiesPlacement: Bool {
        invalidationReason == nil && !isExpired
    }

    /// The ad can no longer be shown. TODO(step 3): tell the delegate (`didInvalidate`).
    func invalidate(_ reason: InvalidationReason) {
        guard invalidationReason == nil else { return }
        invalidationReason = reason
        Logger.debug("ad \(id.prefix(8)) invalidated: \(reason)")
    }
}
