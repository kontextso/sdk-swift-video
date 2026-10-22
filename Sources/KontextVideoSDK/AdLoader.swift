import Foundation

/// Loads ads of one format for one video. Every `VideoAds` has three, created with it and reached by
/// format: `ads.format(.overlay)` (`OverlayLoader`), `ads.format(.pause)` (`PauseLoader`),
/// `ads.format(.linear)` (`LinearLoader`), each with the format's options type. Which configuration the format uses (demand, floors, frequency caps) is
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

    /// The server's answer for this format: the one the creation-time request brought (waiting for that
    /// request while it is in flight), else a fresh fetch with the options declared at creation
    /// (`.default` for a format that was not declared). Throws the format's no-fill once, then asks
    /// again on the next access; `.formatBusy` while an ad of this format is loading or loaded and not
    /// yet shown. Nothing is rendered: `bid.load()` renders, `load()` is the two in one.
    public var bid: VideoAd.Bid {
        get async throws {
            guard let ads, !ads.isDestroyed else { throw VideoAdError.destroyed }
            await slot.inFlight?.value
            if let bid = slot.takeHeldBid() { return bid }
            if let reason = slot.takeNoFillReason() { throw VideoAdError.noFill(reason: reason) }
            return try await ads.fetch(slot: slot, request: declaredRequest)
        }
    }

    /// Asks the server for this one format, with these options, now: a fresh answer, which `bid` then
    /// holds. An answer the app never took is replaced; one it holds makes the loader `.formatBusy`
    /// until loaded or dropped. See the options type for what can be asked.
    public func fetch(_ options: Options = .default) async throws -> VideoAd.Bid {
        guard let ads, !ads.isDestroyed else { throw VideoAdError.destroyed }
        await slot.inFlight?.value
        slot.dropHeld()
        return try await ads.fetch(slot: slot, request: options.request)
    }

    /// The bid, rendered: ready to show, or throws. With options, a fresh fetch with them first.
    public func load(_ options: Options? = nil) async throws -> VideoAd {
        let bid = if let options { try await fetch(options) } else { try await bid }
        return try await bid.load()
    }

    private var declaredRequest: FormatRequest {
        slot.declared ?? Options.default.request
    }
}

/// A strip across the player while the content plays, shown at a moment the app picks.
public typealias OverlayLoader = AdLoader<OverlayOptions>
/// A card at the top or bottom, or the full player, while the content is paused.
public typealias PauseLoader = AdLoader<PauseOptions>
/// A full-screen video at a moment the app picks: before, during or after the content.
public typealias LinearLoader = AdLoader<LinearOptions>

/// The key `VideoAds.format(_:)` takes: a format, carrying its options type so the loader it returns is
/// typed. `.overlay`, `.pause`, `.linear`; a named ad unit of a format can be added here later.
public struct FormatKey<Options: AdOptions>: Sendable {
    let format: AdFormat
}

public extension FormatKey where Options == OverlayOptions {
    static var overlay: FormatKey { FormatKey(format: .overlay) }
}

public extension FormatKey where Options == PauseOptions {
    static var pause: FormatKey { FormatKey(format: .pause) }
}

public extension FormatKey where Options == LinearOptions {
    static var linear: FormatKey { FormatKey(format: .linear) }
}

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
    /// The format's options as declared at creation; what `bid` fetches with when it holds nothing.
    var declared: FormatRequest?
    /// The creation-time request, while it runs; `bid` and `fetch` wait for it.
    var inFlight: Task<Void, Never>?
    /// The creation-time answer the app has not taken yet: held strongly, nobody else has it. Handed out
    /// once by `takeHeldBid`, after which `pendingBid` knows it weakly like any bid.
    private(set) var prefetched: VideoAd.Bid?
    /// The creation-time no-fill, thrown once by the loader.
    var noFillReason: String?
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

    func didPrefetch(_ bid: VideoAd.Bid) {
        prefetched = bid
        noFillReason = nil
    }

    /// The creation-time answer, once; a pending bid the app holds, as long as it is pending.
    func takeHeldBid() -> VideoAd.Bid? {
        if let bid = prefetched {
            prefetched = nil
            if bid.isPending { pendingBid = bid; return bid }
            return nil
        }
        if let bid = pendingBid, bid.isPending { return bid }
        return nil
    }

    func takeNoFillReason() -> String? {
        defer { noFillReason = nil }
        return noFillReason
    }

    /// Forgets an answer the app never took, so a fresh fetch replaces it.
    func dropHeld() {
        prefetched?.invalidate(.targetingChanged)
        prefetched = nil
        noFillReason = nil
    }

    func didStartRendering(_ ad: VideoAd) {
        pendingAd = ad
        pendingBid = nil
    }

    func didFailRendering() { pendingAd = nil }

    func didBeginShowing(_ ad: VideoAd) { showing = ad }

    func didEnd(_ ad: VideoAd) {
        if showing === ad { showing = nil }
    }

    /// The ad and the bid still around and not yet gone: the app's, or the creation-time answer not taken.
    var live: (ad: VideoAd?, bid: VideoAd.Bid?) {
        let bid = prefetched ?? pendingBid
        return (pendingAd?.isPendingUnshown == true ? pendingAd : nil, bid?.isPending == true ? bid : nil)
    }

    func clear() {
        showing = nil
        pendingAd = nil
        pendingBid = nil
        prefetched = nil
        noFillReason = nil
    }
}
