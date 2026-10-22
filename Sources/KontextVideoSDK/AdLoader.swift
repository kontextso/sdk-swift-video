import Foundation

/// Loads ads of one format for one video. Every `VideoAds` has three, created with it: `ads.overlay`
/// (`OverlayLoader`), `ads.pause` (`PauseLoader`) and `ads.linear` (`LinearLoader`), each with the
/// format's options type. Which configuration the format uses (demand, floors, frequency caps) is
/// decided in the Kontext dashboard, per publisher; the app names nothing.
///
/// One unshown ad per loader at a time: `load` returns the ad, ready to show, or throws a `VideoAdError`
/// (no fill, a busy loader, a failed request, an SDK that is not ready) or `CancellationError`. `fetch`
/// is the first half of `load`: the server's answer as a `VideoAd.Bid`, nothing rendered, for an app
/// that decides before rendering; `bid.load()` is the second half. A load while the previous ad is on
/// screen is allowed, so the next one is ready when the current one ends.
@MainActor
public final class AdLoader<Options: AdOptions> {
    /// The `VideoAds` it belongs to. Weak, as `Bid.owner`: a loader kept after its `VideoAds` was
    /// released throws `.destroyed` instead of crashing.
    weak var ads: VideoAds?
    /// The per-format state: the pending ad or bid, the request in flight, the ad on screen.
    let slot = AdSlot(format: Options.format)

    init() {}

    /// Requests an ad and renders it: ready to show, or throws. See the options type for what can be asked.
    public func load(_ options: Options = .default) async throws -> VideoAd {
        let bid = try await fetch(options)
        return try await bid.load()
    }

    /// Requests an ad and returns the server's answer without rendering it; `bid.load()` renders.
    public func fetch(_ options: Options = .default) async throws -> VideoAd.Bid {
        guard let ads, !ads.isDestroyed else { throw VideoAdError.destroyed }
        return try await ads.fetch(slot: slot, request: options.request)
    }
}

/// A strip across the player while the content plays, shown at a moment the app picks.
public typealias OverlayLoader = AdLoader<OverlayOptions>
/// A card at the top or bottom, or the full player, while the content is paused.
public typealias PauseLoader = AdLoader<PauseOptions>
/// A full-screen video at a moment the app picks: before, during or after the content.
public typealias LinearLoader = AdLoader<LinearOptions>

/// The options of one format, as its loader's `load` and `fetch` take them.
public protocol AdOptions: Encodable, Sendable {
    /// The format these options belong to; the loader sends it with them.
    static var format: AdFormat { get }
    /// Every option left to its default.
    static var `default`: Self { get }
    /// These options as a request for their format.
    var request: FormatRequest { get }
}

/// The one-unshown-ad-at-a-time state of one format of one `VideoAds`, held by its loader and reached
/// by `VideoAds` by format. The app owns its ads and bids; the slot only knows whether one is around.
@MainActor
final class AdSlot {
    let format: AdFormat
    /// The ad handed out last, while the app keeps it. An ad on screen does not count.
    private(set) weak var pendingAd: VideoAd?
    /// The bid handed out last and not loaded yet; counts like an unshown ad.
    private(set) weak var pendingBid: VideoAd.Bid?
    /// Retained from `show` until `didEnd`, so dropping the app's reference cannot abort an ad on screen.
    private(set) var showing: VideoAd?
    /// A request in flight.
    var isLoading = false

    init(format: AdFormat) {
        self.format = format
    }

    /// Loading, fetched and not loaded, or loaded and not shown.
    var isBusy: Bool {
        isLoading || pendingAd?.isPendingUnshown == true || pendingBid?.isPending == true
    }

    func didFetch(_ bid: VideoAd.Bid) { pendingBid = bid }

    func didStartRendering(_ ad: VideoAd) {
        pendingAd = ad
        pendingBid = nil
    }

    func didFailRendering() { pendingAd = nil }

    func didBeginShowing(_ ad: VideoAd) { showing = ad }

    func didEnd(_ ad: VideoAd) {
        if showing === ad { showing = nil }
    }

    /// The ad and the bid the app still holds and that are not yet gone.
    var live: (ad: VideoAd?, bid: VideoAd.Bid?) {
        (pendingAd?.isPendingUnshown == true ? pendingAd : nil, pendingBid?.isPending == true ? pendingBid : nil)
    }

    func clear() {
        showing = nil
        pendingAd = nil
        pendingBid = nil
    }
}
