import AVFoundation
import Foundation
import UIKit

/// The ads of one video. Create it as early as you like, for example the next episode's while the
/// current one plays; any number can be alive at once. Call `destroy()` when the viewer leaves the video.
/// Ads are loaded through its three loaders, one per format: `overlay`, `pause`, `linear`.
@MainActor
public final class VideoAds {
    public let content: KontextVideo.Content
    /// The size of the player, in points, as given at creation; `nil` means full screen.
    public let playerSize: CGSize?
    /// The bounds of the last view an ad of this `VideoAds` was shown in: the real box, used for every
    /// request after the first `show(in:)` instead of the creation-time hint.
    private var lastShownBox: CGSize?
    /// `true` after `destroy()`: the object does nothing any more.
    public private(set) var isDestroyed = false

    /// Where the SDK reads the content playhead, in seconds, when it needs one: at a request, in the
    /// `[CONTENTPLAYHEAD]` macro of a beacon. For any player; for an `AVPlayer`,
    /// `trackPlayhead(of:)` is the one-liner. Setting it replaces a tracked player. Nothing set: 0,
    /// which is what a request made before the episode plays (a prefetch) should carry.
    public var playheadProvider: (() -> TimeInterval)? {
        didSet { if playheadProvider != nil { trackedPlayer = nil } }
    }
    /// The `AVPlayer` whose `currentTime()` is the playhead; held weakly.
    private weak var trackedPlayer: AVPlayer?

    /// Loads overlays: a strip across the player while the content plays.
    public let overlay = OverlayLoader()
    /// Loads pause ads: a card, or the full player, while the content is paused.
    public let pause = PauseLoader()
    /// Loads linear ads: a full-screen video at a moment the app picks.
    public let linear = LinearLoader()
    /// The loaders' state, by format, for the rules that touch all of them.
    private var slots: [AdFormat: AdSlot] { [.overlay: overlay.slot, .pause: pause.slot, .linear: linear.slot] }

    /// `content` describes the video; `playerSize` is the player's size in points, which lets the server
    /// pick creatives that fit, `nil` (the default) meaning full screen. Needs `initialize(with:)` to have
    /// been called; `/config` itself may still be in flight, loads wait for it.
    public init(content: KontextVideo.Content, playerSize: CGSize? = nil) {
        self.content = content
        self.playerSize = playerSize
        overlay.ads = self
        pause.ads = self
        linear.ads = self
        KontextVideo.shared.register(self)
        Logger.debug("VideoAds created for video \(content.id)")
    }

    /// Reads the content playhead from this `AVPlayer` whenever the SDK needs one; the player is held
    /// weakly and `currentTime()` is read at that moment, no observer is attached. With one `AVPlayer`
    /// reused across episodes, call it when this episode starts playing in it, not at creation: before
    /// that the player's time belongs to the previous episode. Replaces a `playheadProvider`.
    public func trackPlayhead(of player: AVPlayer) {
        playheadProvider = nil
        trackedPlayer = player
    }

    /// Content time in seconds, read now: the provider's, the tracked player's, or 0.
    var playhead: TimeInterval {
        if let playheadProvider {
            let value = playheadProvider()
            return value.isFinite ? max(0, value) : 0
        }
        if let trackedPlayer {
            let time = trackedPlayer.currentTime()
            guard time.isNumeric, !time.seconds.isNaN else { return 0 }
            return max(0, time.seconds)
        }
        return 0
    }

    /// Content time in milliseconds as a request sends it.
    var playheadMs: Int {
        Int((playhead * 1000).rounded())
    }

    /// At most one ad is presented per `VideoAds` at a time, whatever the formats.
    var isShowingAnAd: Bool {
        slots.values.contains { $0.showing != nil }
    }

    func adDidBeginShowing(_ ad: VideoAd, in box: CGSize? = nil) {
        slots[ad.format]?.didBeginShowing(ad)
        if let box, box.width > 0, box.height > 0 { lastShownBox = box }
    }

    func adDidEnd(_ ad: VideoAd) {
        slots[ad.format]?.didEnd(ad)
    }

    /// One request for one format, run on the caller's task so cancelling that task cancels the request.
    /// Returns the server's answer as a bid, nothing rendered, or throws: no fill, a failed request, a busy
    /// loader, an SDK that is not ready. Waits for `/config` when that is still in flight.
    func fetch(slot: AdSlot, request formatRequest: FormatRequest) async throws -> VideoAd.Bid {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard KontextVideo.shared.requireInitialized("load()") else { throw VideoAdError.notInitialized }
        let format = slot.format
        if slot.isBusy {
            Logger.warning("\(format) for \(content.id): load refused, the loader has an ad loading, fetched or loaded and not yet shown")
            throw VideoAdError.formatBusy
        }
        slot.isLoading = true
        defer { slot.isLoading = false }

        guard await KontextVideo.shared.waitUntilEnabled() else {
            Logger.warning("\(format) for \(content.id): not requested, the SDK is \(KontextVideo.shared.state)")
            if case .disabled(let reason) = KontextVideo.shared.state { throw VideoAdError.disabled(reason: reason) }
            throw VideoAdError.initializationFailed
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard let configuration = KontextVideo.shared.configuration else { throw VideoAdError.notInitialized }
        // The ATT dialog, when the publisher left it to the SDK, comes before the first ads request; a
        // status that changed since the last request discards the other loaders' pending ads.
        let tracking = await TrackingInfo.current(requestAuthorization: configuration.requestTrackingAuthorization)
        KontextVideo.shared.noteTrackingAuthorization(tracking.status)
        guard !isDestroyed else { throw VideoAdError.destroyed }
        let request = AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, tracking: tracking, content: content,
                                      player: .make(playerSize: lastShownBox ?? playerSize, playheadMs: playheadMs), formats: [formatRequest])
        Logger.debug("\(format) for \(content.id): requesting at playhead \(request.player.playhead) ms")
        DebugReporter.shared.event("ads.request", state: ["format": .string(format.rawValue), "playhead": .number(Double(request.player.playhead))])

        let response = try await send(request)
        guard !isDestroyed else { throw VideoAdError.destroyed }

        if case .disabled(let reason) = response {
            KontextVideo.shared.disable(reason: reason)
            throw VideoAdError.disabled(reason: reason)
        }
        guard let result = response.result(for: format) else {
            Logger.error("\(format) for \(content.id): the server answered for other formats, not this one")
            throw VideoAdError.request(APIError.decoding(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no formats entry for \(format)"))))
        }
        if let ad = result.ads.first {
            Logger.info("\(format) for \(content.id): ad \(ad.id.prefix(8)), \(ad.price.value) \(ad.price.currency) cpm")
            DebugReporter.shared.event("ads.response", adId: ad.id, state: ["format": .string(format.rawValue), "filled": true])
            let bid = VideoAd.Bid(payload: ad, receivedAt: ProcessInfo.processInfo.systemUptime, owner: self)
            slot.didFetch(bid)
            return bid
        } else {
            let reason = result.noFillReason ?? AdsResponse.unknownReason
            // `formatNotEnabled` is the dashboard, not the moment: say so, it is not "try again later".
            if reason == AdsResponse.formatNotEnabled {
                Logger.error("\(format) for \(content.id): no configuration for this format in the Kontext dashboard (\(reason))")
            } else {
                Logger.info("\(format) for \(content.id): no fill (\(reason))")
            }
            DebugReporter.shared.event("ads.response", state: ["format": .string(format.rawValue), "filled": false, "reason": .string(reason)])
            throw VideoAdError.noFill(reason: reason)
        }
    }

    /// The second half of a load: the page starts loading now, and the ad is returned only when it
    /// reported `ad.loaded`. Called by `Bid.load()`, on the caller's task.
    func render(_ bid: VideoAd.Bid) async throws -> VideoAd {
        guard !isDestroyed, let slot = slots[bid.format] else { throw VideoAdError.destroyed }
        let videoAd = VideoAd(info: bid.info)
        videoAd.owner = self
        slot.didStartRendering(videoAd)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await videoAd.awaitLoaded()
        } catch {
            slot.didFailRendering()
            DebugReporter.shared.event("ad.loadFailed", adId: bid.id, level: .warning, state: ["reason": .string("\(error)")])
            throw error
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        Logger.info("\(bid.format) for \(content.id): ad \(bid.id.prefix(8)) ready in \(durationMs) ms")
        DebugReporter.shared.event("ad.loaded", adId: bid.id, state: ["durationMs": .number(Double(durationMs))])
        return videoAd
    }

    /// Ads requests are never retried by the SDK: a timeout, a server error or a no-fill of any reason is
    /// thrown, and the app asks again at its next natural moment.
    private func send(_ request: AdsRequest) async throws -> AdsResponse {
        let client = APIClient(baseURL: request.adServerURL)
        do {
            return try await client.post("video/ads", body: request)
        } catch let error as APIError {
            // Swift's convention for a cancelled task is `CancellationError`; URLSession says `.cancelled`.
            if case .transport(let urlError) = error, urlError.code == .cancelled { throw CancellationError() }
            if Task.isCancelled { throw CancellationError() }
            Logger.error("\(request.formats.map(\.format)) for \(content.id): request failed, \(error)")
            throw VideoAdError.request(error)
        }
    }

    /// Every ad and bid the loaders handed out that the app still holds and that are not yet gone.
    private var live: (ads: [VideoAd], bids: [VideoAd.Bid]) {
        let live = slots.values.map(\.live)
        return (live.compactMap(\.ad), live.compactMap(\.bid))
    }

    /// The spec's rule: when the viewer's data or consent changes, loaded ads that were not shown, and
    /// bids not loaded yet, are dropped so the next request carries the new values.
    func discardLoadedAds(reason: String) {
        let (ads, pending) = live
        guard !ads.isEmpty || !pending.isEmpty else { return }
        Logger.debug("\(content.id): discarding \(ads.count) loaded ad(s) and \(pending.count) bid(s), \(reason)")
        ads.forEach { $0.invalidate(.targetingChanged) }
        pending.forEach { $0.invalidate(.targetingChanged) }
    }

    /// Deallocation does what `destroy()` does. Loads in flight hold `self` for their duration, so none
    /// is running here; ads on screen are retained by `showing` and end with `.destroyed`.
    deinit {
        let slots = [overlay.slot, pause.slot, linear.slot]
        let showing = slots.compactMap(\.showing)
        let loaded = slots.compactMap(\.pendingAd)
        let pending = slots.compactMap(\.pendingBid)
        guard !showing.isEmpty || !loaded.isEmpty || !pending.isEmpty else { return }
        let teardown: @MainActor () -> Void = {
            loaded.forEach { $0.invalidate(.destroyed) }
            pending.forEach { $0.invalidate(.destroyed) }
            showing.forEach { $0.invalidate(.destroyed) }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            Task { @MainActor in teardown() }
        }
    }

    /// Releases the video's ads. Call it when the viewer leaves the video; deallocation does the same.
    /// Loads in flight fail with `destroyed`, ads the app still holds are invalidated. Terminal: the
    /// loaders throw `destroyed` from `load` afterwards.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        let (ads, pending) = live
        ads.forEach { $0.invalidate(.destroyed) }
        pending.forEach { $0.invalidate(.destroyed) }
        slots.values.forEach { slot in
            slot.showing?.invalidate(.destroyed)
            slot.clear()
        }
        Logger.debug("VideoAds destroyed for video \(content.id)")
    }
}
