import AVFoundation
import Foundation
import UIKit

/// The ads of one video. Create it as early as you like, for example the next episode's while the
/// current one plays; any number can be alive at once. Call `destroy()` when the viewer leaves the video.
@MainActor
public final class VideoAds {
    /// A weak hold on an ad handed to the app: the app owns it, the placement only needs to know whether
    /// one is still around for its one-at-a-time rule.
    private struct WeakAd {
        weak var value: VideoAd?
        init(_ value: VideoAd) { self.value = value }
    }

    private struct WeakBid {
        weak var value: VideoAd.Bid?
        init(_ value: VideoAd.Bid) { self.value = value }
    }

    public let content: KontextVideo.Content
    /// The size of the player, in points, as given at creation; `nil` means full screen.
    public let playerSize: CGSize?
    /// The bounds of the last view an ad of this `VideoAds` was shown in: the real box, used for every
    /// request after the first `show(in:)` instead of the creation-time hint.
    private var lastShownBox: CGSize?
    /// The render budget: how many rendered, unshown ads may exist at a time across all `VideoAds` of
    /// the app. A rendered ad is a live WebView with its media; a fetched bid is not rendered.
    nonisolated(unsafe) static var renderBudget = 3
    /// `true` after `destroy()`: the object does nothing any more.
    public private(set) var isDestroyed = false

    /// Where the SDK reads the content playhead, in seconds, when it needs one: at a request, in the
    /// `[CONTENTPLAYHEAD]` macro of a beacon, in timed mode. For any player; for an `AVPlayer`,
    /// `trackPlayhead(of:)` is the one-liner. Setting it replaces a tracked player. Nothing set: 0,
    /// which is what a request made before the episode plays (a prefetch) should carry.
    public var playheadProvider: (() -> TimeInterval)? {
        didSet { if playheadProvider != nil { trackedPlayer = nil } }
    }
    /// The `AVPlayer` whose `currentTime()` is the playhead; held weakly.
    private weak var trackedPlayer: AVPlayer? {
        didSet { observeTimeJumps() }
    }

    /// Timed mode: told when a load for a placement makes sense. Held weakly.
    public weak var timingDelegate: (any VideoAdsTimingDelegate)?

    /// Timed mode's clock: how often the playhead is sampled while there is something to watch.
    static var sampleInterval: TimeInterval = 0.25
    /// A jump between two samples larger than this, in either direction, is a seek.
    static var seekThreshold: TimeInterval = 2
    private var monitor: Timer?
    private var lastSample: TimeInterval?
    private var timeJumpObserver: NSObjectProtocol?
    private var noPlayheadSourceLogged = false

    /// The placement objects handed out, by format and id: the same typed lookup gives the same object.
    /// The one-ad-at-a-time state lives in this class keyed by id alone, so two typed handles for one id
    /// share it; whichever format is wrong hears it from the server (`invalidPlacement`).
    private var placements: [String: AnyObject] = [:]

    /// One unshown ad per placement at a time: the ad each placement handed out last, while the app keeps
    /// it. An ad on screen does not count; the next one may load while it shows.
    private var current: [String: WeakAd] = [:]
    /// The bid each placement handed out last and the app has not loaded yet; counts like an unshown ad.
    private var bids: [String: WeakBid] = [:]
    /// Ads on screen, retained from `show` until `didEnd` so dropping the app's reference cannot abort them.
    private var showing: [String: VideoAd] = [:]
    /// Timed mode: the content time (ms) at which the server recommends the placement's next request.
    /// A recommendation, not a rule: an earlier `load` is an ordinary request.
    private(set) var nextRequestAt: [String: Int] = [:]
    /// Timed mode: placements whose `nextRequestAt` came while they were busy (an unshown ad or a
    /// pending bid); the request is reported when the placement is free again, not lost.
    private(set) var deferredRequests: Set<String> = []
    /// Placements with a request in flight.
    private var loading: Set<String> = []

    /// `content` describes the video; `playerSize` is the player's size in points, which lets the server
    /// pick creatives that fit, `nil` (the default) meaning full screen. Needs `initialize(with:)` to have
    /// been called; `/init` itself may still be in flight, loads wait for it.
    public init(content: KontextVideo.Content, playerSize: CGSize? = nil) {
        self.content = content
        self.playerSize = playerSize
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

    /// Whether the SDK has anywhere to read the playhead from.
    var hasPlayheadSource: Bool {
        playheadProvider != nil || trackedPlayer != nil
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

    /// The overlay placement with this id, as created in the Kontext dashboard. Get it once and keep it.
    public func overlayPlacement(_ id: String) -> OverlayPlacement {
        placement(id) { OverlayPlacement(id: id, ads: self) }
    }

    /// The pause placement with this id, as created in the Kontext dashboard. Get it once and keep it.
    public func pausePlacement(_ id: String) -> PausePlacement {
        placement(id) { PausePlacement(id: id, ads: self) }
    }

    /// The linear placement with this id, as created in the Kontext dashboard. Get it once and keep it.
    public func linearPlacement(_ id: String) -> LinearPlacement {
        placement(id) { LinearPlacement(id: id, ads: self) }
    }

    /// One object per (format, id).
    private func placement<P: AnyObject>(_ id: String, make: () -> P) -> P {
        let key = "\(P.self):\(id)"
        if let placement = placements[key] as? P { return placement }
        let placement = make()
        placements[key] = placement
        return placement
    }

    /// One unshown ad per placement: loading, fetched and not loaded, or loaded and not shown.
    private func isBusy(_ id: String) -> Bool {
        loading.contains(id) || current[id]?.value?.isPendingUnshown == true || bids[id]?.value?.isPending == true
    }

    /// Every ad this object handed out that the app still holds and that is not yet gone.
    private var liveAds: [VideoAd] {
        current.values.compactMap(\.value)
    }

    /// At most one ad is presented per `VideoAds` at a time, whatever the formats.
    var isShowingAnAd: Bool {
        !showing.isEmpty
    }

    /// A pending (unshown) ad or bid of a placement is gone before it was shown: the placement is free
    /// and a load makes sense, so the timing delegate hears it, once, whatever the reason, except
    /// `.destroyed` (nothing to load into) and `.seeked` (reported per placement by the seek itself).
    /// A deferred `nextRequestAt` of the placement is folded in: one request, not two.
    func pendingAdWasDiscarded(placementId id: String, reason: VideoAd.InvalidationReason) {
        guard !isDestroyed, reason != .destroyed, reason != .seeked else { return }
        deferredRequests.remove(id)
        timingDelegate?.videoAds(self, didRequestLoadOf: id, reason: .adDiscarded(reason))
        updateMonitor()
    }

    func adDidBeginShowing(_ ad: VideoAd, in box: CGSize? = nil) {
        showing[ad.placementId] = ad
        if let box, box.width > 0, box.height > 0 { lastShownBox = box }
        updateMonitor()
    }

    func adDidEnd(_ ad: VideoAd) {
        if showing[ad.placementId] === ad { showing[ad.placementId] = nil }
        updateMonitor()
    }

    /// `fetch` then `load` on the bid, in one call: the ad, ready to show, or an error from either step.
    func load(_ format: FormatRequest) async throws -> VideoAd {
        try checkRenderBudget(placementId: format.placementId)   // before the request: a load that cannot render asks for nothing
        let bid = try await fetch(format)
        return try await bid.load()
    }

    /// The render budget: at most `renderBudget` rendered, unshown ads across the app's `VideoAds`.
    private func checkRenderBudget(placementId: String) throws {
        guard RenderedAds.count < Self.renderBudget else {
            Logger.warning("\(placementId) for \(content.id): \(Self.renderBudget) rendered ads are already waiting to be shown; load refused")
            throw VideoAdError.tooManyLoadedAds
        }
    }

    /// One request for one placement, run on the caller's task so cancelling that task cancels the request.
    /// Returns the server's answer as a bid, nothing rendered, or throws: no fill, a failed request, a busy
    /// placement, an SDK that is not ready. Waits for `/init` when that is still in flight.
    func fetch(_ format: FormatRequest) async throws -> VideoAd.Bid {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard KontextVideo.shared.requireInitialized("load()") else { throw VideoAdError.notInitialized }
        let id = format.placementId
        if isBusy(id) {
            Logger.warning("\(id) for \(content.id): load refused, the placement has an ad loading, fetched or loaded and not yet shown")
            throw VideoAdError.placementBusy
        }
        loading.insert(id)
        defer { loading.remove(id) }

        guard await KontextVideo.shared.waitUntilEnabled() else {
            Logger.warning("\(id) for \(content.id): not requested, the SDK is \(KontextVideo.shared.state)")
            if case .disabled(let reason) = KontextVideo.shared.state { throw VideoAdError.disabled(reason: reason) }
            throw VideoAdError.initializationFailed
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard let configuration = KontextVideo.shared.configuration else { throw VideoAdError.notInitialized }
        // The ATT dialog, when the publisher left it to the SDK, comes before the first ads request.
        let tracking = await TrackingInfo.current(requestAuthorization: configuration.requestTrackingAuthorization)
        guard !isDestroyed else { throw VideoAdError.destroyed }
        let request = AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, tracking: tracking, content: content,
                                      player: .make(playerSize: lastShownBox ?? playerSize, playheadMs: playheadMs), format: format)
        Logger.debug("\(id) for \(content.id): requesting \(format.format) at playhead \(request.player.playhead) ms")
        DebugReporter.shared.event("ads.request", state: ["placementId": .string(id), "format": .string(format.format.rawValue), "playhead": .number(Double(request.player.playhead))])

        var response = try await send(request, format: format)
        if case .noFill(let reason, let retryAfter?, _) = response {
            // The one retry the SDK does by itself: the server asked for it (`temporaryError`).
            Logger.info("\(id) for \(content.id): no fill (\(reason)), retrying in \(retryAfter) ms as the server asked")
            try await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000)
            guard !isDestroyed else { throw VideoAdError.destroyed }
            var retry = request
            retry.requestId = UUID().uuidString.lowercased()
            response = try await send(retry, format: format)
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }

        switch response {
        case .ad(let ad, let next):
            nextRequestAt[id] = next
            Logger.info("\(id) for \(content.id): \(ad.format) ad \(ad.id.prefix(8)) \(describe(ad.trigger)), \(ad.price.value) \(ad.price.currency) cpm\(next.map { ", next request at \($0) ms" } ?? "")")
            DebugReporter.shared.event("ads.response", adId: ad.id, state: ["placementId": .string(id), "filled": true])
            let bid = VideoAd.Bid(payload: ad, receivedAt: ProcessInfo.processInfo.systemUptime, owner: self)
            bids[id] = WeakBid(bid)
            if case .window = ad.trigger { warnIfNoPlayheadSource() }
            updateMonitor()
            return bid
        case .noFill(let reason, let retryAfter, let next):
            nextRequestAt[id] = next
            Logger.info("\(id) for \(content.id): no fill (\(reason))\(next.map { ", next request at \($0) ms" } ?? "")")
            DebugReporter.shared.event("ads.response", state: ["placementId": .string(id), "filled": false, "reason": .string(reason)])
            updateMonitor()
            throw VideoAdError.noFill(reason: reason, retryAfter: retryAfter.map { TimeInterval($0) / 1000 })
        case .disabled(let reason):
            KontextVideo.shared.disable(reason: reason)
            throw VideoAdError.disabled(reason: reason)
        }
    }

    /// The second half of a load: the page starts loading now, and the ad is returned only when it
    /// reported `ad.loaded`. Called by `Bid.load()`, on the caller's task.
    func render(_ bid: VideoAd.Bid) async throws -> VideoAd {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        let id = bid.placementId
        try checkRenderBudget(placementId: id)
        let videoAd = VideoAd(ad: bid.payload, facts: bid.facts)
        RenderedAds.add(videoAd)
        videoAd.owner = self
        current[id] = WeakAd(videoAd)
        bids[id] = nil
        updateMonitor()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await videoAd.awaitLoaded()
        } catch {
            current[id] = nil
            DebugReporter.shared.event("ad.loadFailed", adId: bid.id, level: "warning", state: ["reason": .string("\(error)")])
            throw error
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        Logger.info("\(id) for \(content.id): ad \(bid.id.prefix(8)) ready in \(durationMs) ms")
        DebugReporter.shared.event("ad.loaded", adId: bid.id, state: ["durationMs": .number(Double(durationMs))])
        return videoAd
    }

    /// Ads requests are not retried by the SDK (beyond the server's own `retryAfter`): a timeout counts as
    /// `temporaryError`, and the app asks again at the placement's next natural moment.
    private func send(_ request: AdsRequest, format: FormatRequest) async throws -> AdsResponse {
        let client = APIClient(baseURL: request.adServerURL)
        do {
            return try await client.post("video/ads", body: request)
        } catch let error as APIError {
            // Swift's convention for a cancelled task is `CancellationError`; URLSession says `.cancelled`.
            if case .transport(let urlError) = error, urlError.code == .cancelled { throw CancellationError() }
            if Task.isCancelled { throw CancellationError() }
            if case .http(400, let errors) = error, let problem = invalidPlacement(in: errors, format: format) {
                Logger.error("\(request.placementId) for \(content.id): \(VideoAdError.invalidPlacement(problem))")
                throw VideoAdError.invalidPlacement(problem)
            }
            Logger.error("\(request.placementId) for \(content.id): request failed, \(error)")
            throw VideoAdError.request(error)
        }
    }

    /// The server's dedicated codes for a wrong placement id, so the app reads a sentence, not a 400.
    private func invalidPlacement(in errors: [APIErrorResponse.Item], format: FormatRequest) -> VideoAdError.InvalidPlacement? {
        for item in errors {
            switch item.code {
            case "unknownPlacement":
                return .unknown(id: format.placementId)
            case "placementFormatMismatch":
                // `detail` reads "expected overlay, got linear" when the server names the dashboard's format.
                let expected = item.detail.flatMap { detail -> AdFormat? in
                    guard let range = detail.range(of: "expected ") else { return nil }
                    let word = detail[range.upperBound...].prefix { $0.isLetter }
                    return AdFormat(rawValue: String(word))
                }
                return .formatMismatch(id: format.placementId, expected: expected, actual: format.format)
            default:
                continue
            }
        }
        return nil
    }

    /// Every bid this object handed out that the app still holds and has not loaded or lost.
    private var liveBids: [VideoAd.Bid] {
        bids.values.compactMap(\.value)
    }

    /// The spec's rule: when the viewer's data or consent changes, loaded ads that were not shown, and
    /// bids not loaded yet, are dropped so the next request carries the new values.
    func discardLoadedAds(reason: String) {
        let ads = liveAds.filter(\.isPendingUnshown)
        let pending = liveBids.filter(\.isPending)
        guard !ads.isEmpty || !pending.isEmpty else { return }
        Logger.debug("\(content.id): discarding \(ads.count) loaded ad(s) and \(pending.count) bid(s), \(reason)")
        ads.forEach { $0.invalidate(.targetingChanged) }
        pending.forEach { $0.invalidate(.targetingChanged) }
    }

    /// Deallocation does what `destroy()` does. Loads in flight hold `self` for their duration, so none
    /// is running here; ads on screen are retained by `showing` and end with `.destroyed`.
    deinit {
        monitor?.invalidate()
        if let timeJumpObserver { NotificationCenter.default.removeObserver(timeJumpObserver) }
        let showing = Array(self.showing.values)
        let loaded = current.values.compactMap(\.value)
        let pending = bids.values.compactMap(\.value)
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
    /// Loads in flight fail with `destroyed`, ads the app still holds are invalidated. Terminal: placements
    /// the app kept, and any looked up afterwards, throw `destroyed` from `load`.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        liveAds.forEach { $0.invalidate(.destroyed) }
        liveBids.forEach { $0.invalidate(.destroyed) }
        showing.values.forEach { $0.invalidate(.destroyed) }
        showing.removeAll()
        current.removeAll()
        bids.removeAll()
        nextRequestAt.removeAll()
        deferredRequests.removeAll()
        stopMonitor()
        Logger.debug("VideoAds destroyed for video \(content.id)")
    }

    // MARK: Timed mode

    /// Timed mode runs on a clock only while there is something to watch: a windowed ad not yet shown, a
    /// `nextRequestAt`, a windowed overlay on screen (a seek out of its window ends it).
    private var needsMonitor: Bool {
        guard !isDestroyed else { return false }
        if !nextRequestAt.isEmpty || !deferredRequests.isEmpty { return true }
        if liveBids.contains(where: { $0.isPending && $0.isWindowed }) { return true }
        if liveAds.contains(where: { $0.isWindowed && $0.isPendingUnshown }) { return true }
        return showing.values.contains { $0.isWindowed && $0.format == .overlay }
    }

    private func updateMonitor() {
        if needsMonitor {
            guard monitor == nil else { return }
            lastSample = nil
            let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = Self.sampleInterval / 5
            RunLoop.main.add(timer, forMode: .common)
            monitor = timer
            Logger.debug("\(content.id): watching the playhead")
        } else {
            stopMonitor()
        }
    }

    private func stopMonitor() {
        guard let monitor else { return }
        monitor.invalidate()
        self.monitor = nil
        lastSample = nil
        Logger.debug("\(content.id): stopped watching the playhead")
    }

    /// One sample: a seek is a jump; otherwise windows and `nextRequestAt` are detected by crossing, the
    /// last sample before, this one at or past. Apple's advice for boundary observers applies: decide from
    /// the current time, never from a callback that a seek may skip.
    private func tick() {
        let now = playhead
        defer {
            lastSample = now
            if !needsMonitor { stopMonitor() }
        }
        guard let last = lastSample else { return }
        if abs(now - last) > Self.seekThreshold {
            seeked(from: last, to: now)
            return
        }
        for (id, at) in nextRequestAt where now >= TimeInterval(at) / 1000 {
            nextRequestAt[id] = nil
            if isBusy(id) {
                // The placement still holds an unshown ad: a load now would be refused. Reported the
                // moment the placement is free (the next sample), never lost.
                Logger.info("\(id) for \(content.id): nextRequestAt \(at) ms reached while the placement is busy; deferred")
                deferredRequests.insert(id)
            } else {
                Logger.info("\(id) for \(content.id): nextRequestAt \(at) ms reached")
                timingDelegate?.videoAds(self, didRequestLoadOf: id, reason: .nextRequestReached)
            }
        }
        for id in deferredRequests.sorted() where !isBusy(id) {
            deferredRequests.remove(id)
            Logger.info("\(id) for \(content.id): placement free, the deferred nextRequestAt is due")
            timingDelegate?.videoAds(self, didRequestLoadOf: id, reason: .nextRequestReached)
        }
        for bid in liveBids where bid.isPending {
            guard case .window(_, let to) = bid.trigger, now >= to else { continue }
            bid.invalidate(.windowPassed)   // the invalidation reports the load request
        }
        for ad in liveAds where ad.isPendingUnshown {
            guard case .window(let from, let to) = ad.trigger else { continue }
            let fits = ad.format == .overlay ? now + (ad.duration ?? 0) <= to : now < to
            if !fits {
                Logger.info("ad \(ad.id.prefix(8)): window \(from)–\(to) s passed at \(now) s")
                ad.invalidate(.windowPassed)   // the invalidation reports the load request
            } else if now >= from {
                ad.deliverWindow()
            }
        }
    }

    /// The viewer seeked: the pending ads were chosen for the old content time and are stale, the
    /// server's plan is forgotten, and the app hears that a load makes sense for each placement that had
    /// something. An overlay on screen whose window the viewer left ends.
    private func seeked(from: TimeInterval, to: TimeInterval) {
        Logger.info("\(content.id): seek from \(from) s to \(to) s")
        DebugReporter.shared.event("ads.seek", state: ["from": .number(from), "to": .number(to)])
        var placements: [String] = []
        for bid in liveBids where bid.isPending && bid.isWindowed {
            bid.invalidate(.seeked)
            placements.append(bid.placementId)
        }
        for ad in liveAds where ad.isPendingUnshown && ad.isWindowed {
            ad.invalidate(.seeked)
            placements.append(ad.placementId)
        }
        for ad in showing.values where ad.format == .overlay {
            if case .window(let windowFrom, let windowTo) = ad.trigger, !(windowFrom...windowTo).contains(to) {
                Logger.info("ad \(ad.id.prefix(8)): the viewer seeked out of its window")
                ad.end(.interrupted)
            }
        }
        placements.append(contentsOf: nextRequestAt.keys.sorted())
        placements.append(contentsOf: deferredRequests.sorted())
        nextRequestAt.removeAll()
        deferredRequests.removeAll()
        var notified: Set<String> = []
        for id in placements where notified.insert(id).inserted {
            timingDelegate?.videoAds(self, didRequestLoadOf: id, reason: .seeked)
        }
    }

    /// For a tracked `AVPlayer`, Apple's documented seek signal; the sample threshold is the fallback.
    private func observeTimeJumps() {
        if let timeJumpObserver {
            NotificationCenter.default.removeObserver(timeJumpObserver)
            self.timeJumpObserver = nil
        }
        guard trackedPlayer != nil else { return }
        timeJumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.monitor != nil, let item = notification.object as? AVPlayerItem,
                      item === self.trackedPlayer?.currentItem, let last = self.lastSample else { return }
                let now = self.playhead
                guard abs(now - last) > 0.5 else { return }
                self.seeked(from: last, to: now)
                self.lastSample = now
            }
        }
    }

    private func warnIfNoPlayheadSource() {
        guard !hasPlayheadSource, !noPlayheadSourceLogged else { return }
        noPlayheadSourceLogged = true
        Logger.warning("\(content.id): a timed ad arrived but no playhead source is set; call trackPlayhead(of:) or set playheadProvider, or its window can never be detected")
    }

    private func describe(_ trigger: AdPayload.Trigger) -> String {
        switch trigger {
        case .manual: return "manual"
        case .window(let from, let to): return "window \(from)–\(to) ms"
        }
    }
}

/// The rendered, unshown ads of the whole app, for the render budget (`VideoAds.renderBudget`): an ad
/// joins when its page starts loading and leaves when shown, invalidated or deallocated. Weak, so a
/// dropped ad leaves by itself.
@MainActor
enum RenderedAds {
    private struct Entry { weak var value: VideoAd? }
    private static var ads: [Entry] = []

    static var count: Int {
        ads.removeAll { $0.value == nil }
        return ads.count
    }

    static func add(_ ad: VideoAd) {
        ads.append(Entry(value: ad))
    }

    static func remove(_ ad: VideoAd) {
        ads.removeAll { $0.value == nil || $0.value === ad }
    }

    static func reset() {
        ads = []
    }
}
