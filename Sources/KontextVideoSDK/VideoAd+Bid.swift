import Foundation

extension VideoAd {
    /// The server's answer for one format, before anything is rendered: what `VideoAds.format(_:options:)`
    /// returns. Look at its facts (`price`, `size`, `duration`, ...), then `load()` to render it, or drop it.
    ///
    /// ```swift
    /// let pause = try await ads.format(.pause)
    /// if pause.price.value > floor { let ad = try await pause.load() }
    /// ```
    @MainActor
    public final class Bid {
        /// The facts, as the `VideoAd` will report them (`size` may change at `show`).
        public var id: String { received.id }
        public var format: AdFormat { received.format }
        public var price: Price { received.price }
        public var position: Position? { received.position }
        public var size: Size? { received.size }
        /// Every size the creative was built for, the default first; the SDK picks one at `show`.
        public var sizes: [Size] { received.sizes }
        public var duration: TimeInterval? { received.duration }
        public var skipOffset: TimeInterval? { received.skipOffset }
        public var reward: Reward? { received.reward }

        let received: ReceivedAd
        private let slot: AdSlot
        private weak var ads: VideoAds?
        /// The ad `load()` produced, so a second `load()` returns the same one: a bid is not a factory.
        private var ad: VideoAd?

        init(received: ReceivedAd, slot: AdSlot, ads: VideoAds) {
            self.received = received
            self.slot = slot
            self.ads = ads
        }

        /// Renders the creative and returns the ad, ready to show. Throws `creativeFailed(code:)` when the
        /// creative fails or times out, `invalidated(.expired)` once the answer's lifetime ran out,
        /// `formatBusy` while another ad of this format is loading or loaded and not yet shown,
        /// `destroyed`, or `CancellationError`. A second call returns the same ad.
        public func load() async throws -> VideoAd {
            if let ad { return ad }
            guard let ads, !ads.isDestroyed else { throw VideoAdError.destroyed }
            if received.isExpired {
                if slot.held?.id == id { slot.dropHeld() }
                throw VideoAdError.invalidated(.expired)
            }
            let ad = try await ads.render(slot: slot, received: received)
            self.ad = ad
            return ad
        }
    }
}
