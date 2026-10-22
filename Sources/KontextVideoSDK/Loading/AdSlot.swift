import Foundation

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
    private(set) var held: VideoAd.ReceivedAd?
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

    func hold(_ received: VideoAd.ReceivedAd, requestedWith request: FormatRequest) {
        held = received
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
