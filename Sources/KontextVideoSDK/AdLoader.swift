import Foundation

/// The SDK side of one format of one `VideoAds`: hands out the held answer as a `Bid`, fetching when it
/// holds none. Internal; the app reaches it through `VideoAds.format(_:options:)`.
@MainActor
final class AdLoader<Options: AdOptions> {
    /// The `VideoAds` it belongs to. Weak: nothing here keeps the video's ads alive.
    weak var ads: VideoAds?
    /// The per-format state: the held answer, the pending ad, the request in flight, the ad on screen.
    let slot = AdSlot(format: Options.format)

    init() {}

    /// Without options: whatever the loader holds (waiting for a request in flight), else a fetch with the
    /// options declared at creation (`.default` for an undeclared format). With options: the held answer
    /// when it was asked with the same options, else a fetch with them. A no-fill kept from creation or a
    /// refetch is thrown once, unless other options are asked for.
    func bid(options: Options?) async throws -> VideoAd.Bid {
        guard let ads, !ads.isDestroyed else { throw VideoAdError.destroyed }
        await slot.inFlight?.value
        guard !ads.isDestroyed else { throw VideoAdError.destroyed }
        let wanted = options?.request ?? slot.declared ?? Options.default.request
        let answer: VideoAd.Answer
        if options != nil, slot.held != nil, slot.heldRequest != wanted {
            // Asked for other options than the held answer was: it does not answer this; ask anew.
            slot.dropHeld()
            answer = try await ads.fetch(slot: slot, request: wanted)
        } else if let held = slot.held, !held.isExpired {
            answer = held
        } else {
            if slot.held != nil { slot.dropHeld() }
            if options == nil || wanted == slot.declared, let reason = slot.takeNoFillReason() {
                throw VideoAdError.noFill(reason: reason)
            }
            answer = try await ads.fetch(slot: slot, request: wanted)
        }
        // One `Bid` per answer: every call that gets this answer gets this object, so `load()` on any of
        // them returns the same ad and the answer is never rendered twice.
        if let bid = slot.heldBid, bid.answer.info.id == answer.info.id { return bid }
        let bid = VideoAd.Bid(answer: answer, slot: slot, ads: ads)
        slot.heldBid = bid
        return bid
    }
}

/// The key `VideoAds.format(_:options:)` takes: a format, carrying its options type so `options` is
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

/// The options of one format, as `VideoAds.format(_:options:)` and the `formats` declaration take them.
public protocol AdOptions: Encodable, Sendable {
    /// The format these options belong to; the loader sends it with them.
    static var format: AdFormat { get }
    /// Every option left to its default.
    static var `default`: Self { get }
    /// These options as a request for their format.
    var request: FormatRequest { get }
}

/// The state of one format of one `VideoAds`, held by its loader and reached by `VideoAds` by format:
/// the answer waiting to be rendered, the pending ad, the request in flight, the ad on screen.
@MainActor
final class AdSlot {
    let format: AdFormat
    /// The format's options as declared at creation; what the loader fetches with when it holds nothing.
    var declared: FormatRequest?
    /// A request that will fill this slot (the creation-time one, a refetch), while it runs; the loader waits for it.
    var inFlight: Task<Void, Never>?
    /// The server's answer waiting to be rendered: the SDK's, nobody else has it.
    private(set) var held: VideoAd.Answer?
    /// What `held` was asked for with: an `options:` equal to it gets `held`, different ones a new request.
    private(set) var heldRequest: FormatRequest?
    /// The `Bid` handed out for `held`, so a second call gets the same object, not a second wrapper.
    var heldBid: VideoAd.Bid?
    /// A no-fill from a request the loader did not make itself (creation, a refetch), thrown once.
    var noFillReason: String?
    /// The ad handed out last, while the app keeps it. An ad on screen does not count.
    private(set) weak var pendingAd: VideoAd?
    /// Retained from `show` until `didEnd`, so dropping the app's reference cannot abort an ad on screen.
    private(set) var showing: VideoAd?
    /// A request in flight.
    var isLoading = false

    init(format: AdFormat) {
        self.format = format
    }

    /// Loading, or loaded and not shown. A held answer does not count: a fetch replaces it.
    var isBusy: Bool {
        isLoading || pendingAd?.isPendingUnshown == true
    }

    func hold(_ answer: VideoAd.Answer, requestedWith request: FormatRequest) {
        held = answer
        heldRequest = request
        heldBid = nil
        noFillReason = nil
    }

    func takeNoFillReason() -> String? {
        defer { noFillReason = nil }
        return noFillReason
    }

    /// Forgets the held answer (expired, replaced, targeting changed); nothing fires, nothing was rendered.
    func dropHeld() {
        held = nil
        heldRequest = nil
        heldBid = nil
        noFillReason = nil
    }

    /// The answer being rendered is spent; a newer held answer (a fetch replaced it) stays.
    func didStartRendering(_ ad: VideoAd) {
        pendingAd = ad
        if held?.info.id == ad.id { held = nil; heldRequest = nil; heldBid = nil }
    }

    func didFailRendering() { pendingAd = nil }

    func didBeginShowing(_ ad: VideoAd) { showing = ad }

    func didEnd(_ ad: VideoAd) {
        if showing === ad { showing = nil }
    }

    /// The loaded, unshown ad the app still holds.
    var liveAd: VideoAd? {
        pendingAd?.isPendingUnshown == true ? pendingAd : nil
    }

    func clear() {
        showing = nil
        pendingAd = nil
        held = nil
        heldRequest = nil
        heldBid = nil
        noFillReason = nil
    }
}
