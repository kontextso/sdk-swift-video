import AVFoundation
import Foundation
import UIKit

/// The ads of one video (one episode). Creating it sends nothing; every request comes from `format(_:)`.
/// Create the next episode's while the current one plays if you like; any number can be alive at once.
/// Call `destroy()` when the viewer leaves the video; releasing the object does the same, best effort.
@MainActor
public final class VideoAds {
    public let content: KontextVideo.Content
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

    /// One per `VideoAds`, sent with every request: the server keeps the bids it gave out per session.
    let sessionId = UUID().uuidString.lowercased()
    /// The bids, the spent ids and the ad on screen; a reference so `deinit` can reach it.
    private let state = State()
    /// The request in flight: every `format(_:)` meanwhile waits for it instead of sending another.
    private var request: Task<[AdFormat: String], Error>?

    /// Needs `initialize(with:)` to have been called; `/config` itself may still be in flight, requests
    /// wait for it.
    public init(content: KontextVideo.Content) {
        self.content = content
        KontextVideo.shared.requireInitialized("VideoAds(content:)")
        Logger.debug("VideoAds created for video \(content.id)")
    }

    // MARK: Getting a bid

    /// The bid for one format: `try await ads.format(.pause)`, then its `price` and other facts, then
    /// `load()` or `reject()`. Every call asks the server for all formats and lists the unshown bids it holds;
    /// the server returns those unchanged until they expire, so the same bid (and its loaded ad) comes
    /// back, and bids for the other formats wait for their own `format(_:)` call. Calls made while a
    /// request runs share it (`async let` for several formats at once). A failed request returns the held
    /// bid when it is still valid. Throws `noFill(reason:)`, `request` (nothing valid held), `destroyed`,
    /// `disabled(reason:)`, `notInitialized`, `initializationFailed`, or `CancellationError` when the
    /// calling task is cancelled (the request itself continues).
    public func format(_ format: AdFormat) async throws -> VideoAd.Bid {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard KontextVideo.shared.requireInitialized("ads.format(_:)") else { throw VideoAdError.notInitialized }
        let task = request ?? startRequest()
        let noFill: [AdFormat: String]
        do {
            noFill = try await awaitShared(task)
        } catch VideoAdError.request(let error) {
            if let held = state.bids[format], !held.received.isExpired {
                Logger.info("\(format) for \(content.id): request failed, returning the held bid \(held.id.prefix(8))")
                return held
            }
            throw VideoAdError.request(error)
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        if let bid = state.bids[format] { return bid }
        throw VideoAdError.noFill(reason: noFill[format] ?? AdsResponse.unknownReason)
    }

    /// The request belongs to the `VideoAds`, not to the caller: nobody cancels it but `destroy()`.
    /// Expired bids are dropped first (silently; the server knows `expires`), so `held` lists valid ones.
    private func startRequest() -> Task<[AdFormat: String], Error> {
        for bid in Array(state.bids.values) where bid.received.isExpired { bid.invalidate(.expired) }
        let held = AdFormat.allCases.compactMap { state.bids[$0]?.id }
        let task = Task { [weak self] () throws -> [AdFormat: String] in
            defer { self?.request = nil }
            guard let self else { throw VideoAdError.destroyed }
            let response = try await send(held: held)
            guard !isDestroyed else { throw VideoAdError.destroyed }
            return apply(response)
        }
        request = task
        return task
    }

    /// Follows the server for every format, whatever the SDK's own clock says: the same id keeps the bid
    /// unchanged (the re-served payload is ignored); a new id replaces it, as does a no-fill, because the
    /// server replaces a held bid only once it expired. An id the SDK already spent (shown or rejected
    /// while the request ran) is ignored for its format. Returns the no-fill reasons by format.
    private func apply(_ response: AdsResponse) -> [AdFormat: String] {
        var noFill: [AdFormat: String] = [:]
        for format in AdFormat.allCases {
            let current = state.bids[format]
            guard let ad = response.result(for: format)?.ads.first else {
                current?.invalidate(.expired)
                let reason = response.result(for: format)?.noFillReason ?? AdsResponse.unknownReason
                noFill[format] = reason
                logNoFill(format, reason: reason)
                continue
            }
            if let current, current.id == ad.id {
                // Re-served: kept unchanged, unless it expired while the request ran (it never comes back).
                guard current.received.isExpired else { continue }
                current.invalidate(.expired)
            }
            current?.invalidate(.expired)
            if state.spentIds.contains(ad.id) {
                Logger.debug("\(format) for \(content.id): ad \(ad.id.prefix(8)) was already used, ignored")
                noFill[format] = Self.alreadyUsed
                continue
            }
            Logger.info("\(format) for \(content.id): ad \(ad.id.prefix(8)), \(ad.price.value) \(ad.price.currency) cpm")
            DebugReporter.shared.event("ads.response", adId: ad.id, state: ["format": .string(format.rawValue), "filled": true])
            state.bids[format] = VideoAd.Bid(received: ReceivedAd(ad: ad, receivedAt: Environment.now()), owner: self)
        }
        return noFill
    }

    /// The no-fill reason for a format whose answer is an id the SDK already used.
    static let alreadyUsed = "alreadyUsed"

    private func logNoFill(_ format: AdFormat, reason: String) {
        // `formatNotEnabled` is the dashboard, not the moment: say so, it is not "try again later".
        if reason == AdsResponse.formatNotEnabled {
            Logger.error("\(format) for \(content.id): no configuration for this format in the Kontext dashboard (\(reason))")
        } else {
            Logger.info("\(format) for \(content.id): no fill (\(reason))")
        }
        DebugReporter.shared.event("ads.response", state: ["format": .string(format.rawValue), "filled": false, "reason": .string(reason)])
    }

    /// Waits for `/config`, reads the ATT status, builds and sends the request. The kill switch in the
    /// answer switches the whole SDK off and drops every bid, with no notices: the server knows.
    private func send(held: [String]) async throws -> AdsResponse {
        guard await KontextVideo.shared.waitUntilEnabled() else {
            Logger.warning("\(content.id): not requested, the SDK is \(KontextVideo.shared.state)")
            if let reason = KontextVideo.shared.disabledReason { throw VideoAdError.disabled(reason: reason) }
            throw VideoAdError.initializationFailed
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard let configuration = KontextVideo.shared.configuration else { throw VideoAdError.notInitialized }
        // The ATT dialog, when the publisher left it to the SDK, comes before the first ads request.
        let tracking = await TrackingInfo.current(requestAuthorization: configuration.requestTrackingAuthorization)
        guard !isDestroyed else { throw VideoAdError.destroyed }
        let request = AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, tracking: tracking, content: content,
                                      player: .make(playheadMs: playheadMs), sessionId: sessionId, held: held)
        Logger.debug("\(content.id): requesting at playhead \(request.player.playhead) ms, holding \(held.count)")
        DebugReporter.shared.event("ads.request", state: ["held": .number(Double(held.count)), "playhead": .number(Double(request.player.playhead))])

        let response: AdsResponse
        do {
            response = try await APIClient(baseURL: request.adServerURL).post("video/ads", body: request)
        } catch {
            // Only `destroy()` cancels the request.
            if isDestroyed { throw VideoAdError.destroyed }
            Logger.error("\(content.id): request failed, \(error)")
            throw VideoAdError.request(error)
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        if case .disabled(let reason) = response {
            KontextVideo.shared.disable(reason: reason)
            // The reason is never seen: load() and show throw `.disabled` first.
            for bid in Array(state.bids.values) { bid.invalidate(.destroyed) }
            throw VideoAdError.disabled(reason: reason)
        }
        return response
    }

    // MARK: Playhead

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

    // MARK: What the bids and ads report

    /// A bid ended or was shown: it leaves its format, and its id is never accepted again.
    func bidDidEnd(_ bid: VideoAd.Bid) {
        if state.bids[bid.format] === bid { state.bids[bid.format] = nil }
        state.spentIds.insert(bid.id)
    }

    /// Shown: the ad's bid leaves its format, so the next request does not list it.
    func adDidBeginShowing(_ ad: VideoAd) {
        state.showing = ad
        if let bid = ad.bid { bidDidEnd(bid) }
    }

    func adDidEnd(_ ad: VideoAd) {
        if state.showing === ad { state.showing = nil }
    }

    // MARK: Destroying

    /// Releases the video's ads. Call it when the viewer leaves the video. Every held bid, loaded or not,
    /// is dropped with a `notUsed` beacon (`destroyed`) and its WebView released; `load()` and `show` on
    /// them throw `destroyed`; the ad on screen ends with `didEnd(.destroyed)`; a `format()` or `load()` in
    /// flight throws `destroyed`. Calling it twice does nothing; afterwards `format()` throws `destroyed`.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        request?.cancel()
        state.endAll()
        Logger.debug("VideoAds destroyed for video \(content.id)")
    }

    /// Releasing the object does what `destroy()` does, best effort: the beacons leave if the process lives.
    deinit {
        let request = self.request
        let state = self.state
        let teardown: @MainActor () -> Void = {
            request?.cancel()
            state.endAll()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            Task { @MainActor in teardown() }
        }
    }
}

extension VideoAds {
    /// What a `VideoAds` holds, in a class of its own so `deinit` can end it all.
    @MainActor
    final class State {
        /// The unshown bid of each format, at most one.
        var bids: [AdFormat: VideoAd.Bid] = [:]
        /// Ids that left: shown, rejected, expired, failed, destroyed. A response that brings one back is
        /// ignored for its format: the request listed the bid before the app used it.
        var spentIds: Set<String> = []
        /// The ad of this `VideoAds` on screen. `KontextVideo.adOnScreen` retains it too.
        var showing: VideoAd?

        /// `destroy()`: every held bid gets its `notUsed` beacon and ends; the ad on screen ends.
        func endAll() {
            for bid in Array(bids.values) {
                bid.tracker.fire("notUsed", notUsed: .destroyed)
                bid.invalidate(.destroyed)
            }
            bids = [:]
            showing?.end(.destroyed)
            showing = nil
        }
    }
}
