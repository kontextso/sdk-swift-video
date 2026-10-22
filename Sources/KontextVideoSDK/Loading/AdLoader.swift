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
