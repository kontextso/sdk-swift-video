import Foundation

extension VideoAd {
    /// The server's answer to a placement's `fetch()`, before anything is rendered: the facts of the ad
    /// (`price`, `size`, `duration`, ...) and nothing else. For an app that decides before paying
    /// for a WebView, for example one that runs its own auction: drop a losing bid and it costs nothing;
    /// `load()` the winner and it renders into the same `VideoAd` that a placement's `load()` returns.
    /// A bid cannot be shown. The app owns it; the placement holds it weakly for its one-unshown-ad rule.
    @MainActor
    public final class Bid {
        public var id: String { facts.id }
        public var placementId: String { facts.placementId }
        public var format: AdFormat { facts.format }
        public var price: Price { facts.price }
        public var position: Position? { facts.position }
        public var size: Size? { facts.size }
        /// Every size the creative was built for, the default first; the SDK picks one at `show`.
        public var sizes: [Size] { facts.sizes }
        public var duration: TimeInterval? { facts.duration }
        public var skipOffset: TimeInterval? { facts.skipOffset }
        public var reward: Reward? { facts.reward }

        /// Everything the SDK knows about the ad; handed to the `VideoAd` at `load()`.
        let facts: Facts
        /// The `VideoAds` that fetched it; renders it at `load()`.
        weak var owner: VideoAds?
        /// The ad `load()` produced, so a second `load()` returns the same one: a bid is not a factory.
        private(set) var ad: VideoAd?
        /// Set when the bid was discarded before `load()` (targeting changed, `destroy()`), or by `load()`
        /// finding it expired; `load()` throws it.
        private(set) var invalidationReason: InvalidationReason?
        private var isLoading = false

        init(payload: AdPayload, receivedAt: TimeInterval, owner: VideoAds) {
            facts = Facts(ad: payload, receivedAt: receivedAt)
            self.owner = owner
        }

        /// Renders the creative and returns the ad, ready to show, exactly as a placement's `load()`
        /// would. Throws `creativeFailed(code:)` when the creative fails or times out,
        /// `invalidated(.expired)` once the lifetime ran out, `invalidated(.targetingChanged)` when
        /// targeting changed meanwhile, `destroyed`, or `CancellationError`.
        public func load() async throws -> VideoAd {
            if let ad { return ad }
            guard let owner, !owner.isDestroyed else { throw VideoAdError.destroyed }
            if facts.isExpired { invalidate(.expired) }
            if let reason = invalidationReason {
                if reason == .destroyed { throw VideoAdError.destroyed }
                throw VideoAdError.invalidated(reason)
            }
            guard !isLoading else {
                Environment.assertionFailure("KontextVideo: bid \(id.prefix(8)) is already loading")
                throw VideoAdError.placementBusy
            }
            isLoading = true
            defer { isLoading = false }
            let ad = try await owner.render(self)
            self.ad = ad
            return ad
        }

        /// Whether the bid still counts for its placement's one-unshown-ad rule: not loaded yet, not
        /// discarded, not expired.
        var isPending: Bool {
            ad == nil && invalidationReason == nil && !facts.isExpired
        }

        /// Discarded before `load()`; the app learns it when `load()` throws.
        func invalidate(_ reason: InvalidationReason) {
            guard ad == nil, invalidationReason == nil else { return }
            invalidationReason = reason
            Logger.debug("bid \(id.prefix(8)) invalidated: \(reason)")
        }
    }

    /// The ad as the SDK knows it, built once from the wire object; the only place that reads `AdPayload`.
    /// `Bid` and `VideoAd` both forward the public facts, in seconds whatever the wire sends; the rest is
    /// what the renderer needs.
    struct Facts {
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
