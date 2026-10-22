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

    private let overlay = AdLoader<OverlayOptions>()
    private let pause = AdLoader<PauseOptions>()
    private let linear = AdLoader<LinearOptions>()
    /// The loaders' state, by format, for the rules that touch all of them.
    private var slots: [AdFormat: AdSlot] { [.overlay: overlay.slot, .pause: pause.slot, .linear: linear.slot] }

    /// The server's answer for one format, nothing rendered yet: `try await ads.format(.pause)`, then its
    /// `price` and other facts, then `load()`. Without options: the answer the creation-time request (or
    /// a refetch) brought, waiting for it while it is in flight, else one fetched now with the options
    /// declared at creation; a no-fill is thrown once, and the next call asks again. With options: the
    /// held answer when it was asked with the same options, else a fresh request with them. Throws `.formatBusy` while an ad of this format is loading or loaded and
    /// not yet shown, and the request-side errors (`noFill`, `request`, the initialisation cases).
    public func format<Options: AdOptions>(_ key: FormatKey<Options>, options: Options? = nil) async throws -> VideoAd.Bid {
        try await loader(key).bid(options: options)
    }

    /// The three are the only `AdLoader`s with these `Options`; the cast cannot fail.
    func loader<Options: AdOptions>(_ key: FormatKey<Options>) -> AdLoader<Options> {
        switch key.format {
        case .overlay: return overlay as! AdLoader<Options>
        case .pause: return pause as! AdLoader<Options>
        case .linear: return linear as! AdLoader<Options>
        }
    }

    /// The request for the declared formats, sent at creation; the loaders wait for it.
    private var prefetch: Task<Void, Never>?

    /// `content` describes the video; `playerSize` is the player's size in points, which lets the server
    /// pick creatives that fit, `nil` (the default) meaning full screen. `formats` are the formats this
    /// video will show, each with its options and each at most once: one `/video/ads` request for all of
    /// them is sent now, with the playhead the object reports (0 before playback), and each format's
    /// answer waits in its loader. Empty (the default): nothing is requested until a loader is used. Every
    /// declared format is an auction the server runs, so declare what the video will show. Needs
    /// `initialize(with:)` to have been called; `/config` itself may still be in flight, requests wait for it.
    public init(content: KontextVideo.Content, playerSize: CGSize? = nil, formats: [FormatRequest] = []) {
        self.content = content
        self.playerSize = playerSize
        overlay.ads = self
        pause.ads = self
        linear.ads = self
        KontextVideo.shared.register(self)
        Logger.debug("VideoAds created for video \(content.id)")
        var declared: [FormatRequest] = []
        for request in formats where !declared.contains(where: { $0.format == request.format }) {
            declared.append(request)
        }
        if declared.count != formats.count {
            // Each format at most once: a bug in the app. Debug build: assertion. Release: the first entry counts.
            Environment.assertionFailure("KontextVideo: VideoAds(formats:) lists a format twice; each format at most once")
            Logger.error("\(content.id): VideoAds(formats:) lists a format twice; the first entry counts")
        }
        for request in declared { slots[request.format]?.declared = request }
        guard !declared.isEmpty else { return }
        let involved = declared.compactMap { slots[$0.format] }
        involved.forEach { $0.isLoading = true }
        prefetch = Task { [weak self] in
            await self?.prefetch(declared, into: involved)
        }
        involved.forEach { $0.inFlight = prefetch }
    }

    /// The creation-time request: every declared format at once. A no-fill is kept in the format's slot
    /// and thrown by its loader once; a failed request is logged and the loaders fetch on first use.
    private func prefetch(_ formats: [FormatRequest], into slots: [AdSlot]) async {
        defer { slots.forEach { $0.isLoading = false; $0.inFlight = nil } }
        do {
            let response = try await request(formats)
            for slot in slots {
                guard let asked = formats.first(where: { $0.format == slot.format }) else { continue }
                do {
                    slot.hold(try receivedAd(from: response, for: slot.format), requestedWith: asked)
                } catch VideoAdError.noFill(let reason) {
                    slot.noFillReason = reason
                } catch {
                    Logger.warning("\(slot.format) for \(content.id): no answer in the creation-time request (\(error))")
                }
            }
        } catch {
            Logger.warning("\(content.id): the creation-time request failed, the loaders fetch on first use: \(error)")
        }
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
        guard let slot = slots[ad.format] else { return }
        slot.didEnd(ad)
        refetchIfConfigured(slot)
    }

    /// The format's `RefetchPolicy.afterEnd`: one request for the next ad, with the declared options, held
    /// like the creation-time answer so the next `load()` renders at once. Not while the loader is busy
    /// (the app already loaded the next one) and never after `destroy()`.
    private func refetchIfConfigured(_ slot: AdSlot) {
        guard !isDestroyed, KontextVideo.shared.configuration?.formatDefaults[slot.format]?.refetch == .afterEnd else { return }
        guard !slot.isBusy, slot.held == nil else { return }
        let request = slot.declared ?? Self.defaultRequest(for: slot.format)
        Logger.debug("\(slot.format) for \(content.id): fetching the next ad after the last one ended")
        slot.isLoading = true
        slot.inFlight = Task { [weak self] in
            guard let self else { return }
            await self.prefetch([request], into: [slot])
        }
    }

    private static func defaultRequest(for format: AdFormat) -> FormatRequest {
        switch format {
        case .overlay: return .overlay()
        case .pause: return .pause()
        case .linear: return .linear()
        }
    }

    /// One request for one format, run on the caller's task so cancelling that task cancels the request.
    /// Returns the server's answer, held by the slot, nothing rendered, or throws: no fill, a failed
    /// request, a busy loader, an SDK that is not ready. Waits for `/config` when that is still in flight.
    func fetch(slot: AdSlot, request formatRequest: FormatRequest) async throws -> VideoAd.ReceivedAd {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard KontextVideo.shared.requireInitialized("load()") else { throw VideoAdError.notInitialized }
        let format = slot.format
        if slot.isBusy {
            Logger.warning("\(format) for \(content.id): load refused, the loader has an ad loading, fetched or loaded and not yet shown")
            throw VideoAdError.formatBusy
        }
        slot.isLoading = true
        defer { slot.isLoading = false }
        let response = try await request([formatRequest])
        let received = try receivedAd(from: response, for: format)
        slot.hold(received, requestedWith: formatRequest)
        return received
    }

    /// The request pipeline every fetch shares: wait for `/config`, read the ATT status, build and send.
    private func request(_ formats: [FormatRequest]) async throws -> AdsResponse {
        let names = formats.map(\.format)
        guard await KontextVideo.shared.waitUntilEnabled() else {
            Logger.warning("\(names) for \(content.id): not requested, the SDK is \(KontextVideo.shared.state)")
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
                                      player: .make(playerSize: lastShownBox ?? playerSize, playheadMs: playheadMs), formats: formats)
        Logger.debug("\(names) for \(content.id): requesting at playhead \(request.player.playhead) ms")
        DebugReporter.shared.event("ads.request", state: ["formats": .string(names.map(\.rawValue).joined(separator: ",")), "playhead": .number(Double(request.player.playhead))])

        let response = try await send(request)
        guard !isDestroyed else { throw VideoAdError.destroyed }
        if case .disabled(let reason) = response {
            KontextVideo.shared.disable(reason: reason)
            throw VideoAdError.disabled(reason: reason)
        }
        return response
    }

    /// One format's answer, or its no-fill thrown.
    private func receivedAd(from response: AdsResponse, for format: AdFormat) throws -> VideoAd.ReceivedAd {
        guard let result = response.result(for: format) else {
            Logger.error("\(format) for \(content.id): the server answered for other formats, not this one")
            throw VideoAdError.request(APIError.decoding(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no formats entry for \(format)"))))
        }
        if let ad = result.ads.first {
            if result.ads.count > 1 {
                // `ads` is a sequence; the SDK shows one per load today and takes the first.
                Logger.debug("\(format) for \(content.id): \(result.ads.count) ads in the answer, taking the first")
            }
            Logger.info("\(format) for \(content.id): ad \(ad.id.prefix(8)), \(ad.price.value) \(ad.price.currency) cpm")
            DebugReporter.shared.event("ads.response", adId: ad.id, state: ["format": .string(format.rawValue), "filled": true])
            return VideoAd.ReceivedAd(ad: ad, receivedAt: ProcessInfo.processInfo.systemUptime)
        }
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

    /// The second half of a load: the page starts loading now, and the ad is returned only when it
    /// reported `ad.loaded`. Called by the loader's `load()`, on the caller's task; the slot's held answer
    /// is consumed.
    func render(slot: AdSlot, received: VideoAd.ReceivedAd) async throws -> VideoAd {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        if slot.isBusy {
            Logger.warning("\(slot.format) for \(content.id): load refused, the loader has an ad loading, or loaded and not yet shown")
            throw VideoAdError.formatBusy
        }
        let videoAd = VideoAd(received: received)
        videoAd.owner = self
        slot.didStartRendering(videoAd)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await videoAd.awaitLoaded()
        } catch {
            slot.didFailRendering()
            DebugReporter.shared.event("ad.loadFailed", adId: videoAd.id, level: .warning, state: ["reason": .string("\(error)")])
            throw error
        }
        guard !isDestroyed else { throw VideoAdError.destroyed }
        let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        Logger.info("\(slot.format) for \(content.id): ad \(videoAd.id.prefix(8)) ready in \(durationMs) ms")
        DebugReporter.shared.event("ad.loaded", adId: videoAd.id, state: ["durationMs": .number(Double(durationMs))])
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
            Logger.error("\(request.formats.map(\.request.format)) for \(content.id): request failed, \(error)")
            throw VideoAdError.request(error)
        }
    }

    /// The loaded, unshown ads the app still holds.
    private var liveAds: [VideoAd] {
        slots.values.compactMap(\.liveAd)
    }

    /// The spec's rule: when the viewer's data or consent changes, loaded ads that were not shown are
    /// discarded, and answers held but not rendered are dropped, so the next request carries the new values.
    func discardLoadedAds(reason: String) {
        let ads = liveAds
        let held = slots.values.filter { $0.held != nil }
        guard !ads.isEmpty || !held.isEmpty else { return }
        Logger.debug("\(content.id): discarding \(ads.count) loaded ad(s) and \(held.count) held answer(s), \(reason)")
        ads.forEach { $0.invalidate(.targetingChanged) }
        held.forEach { $0.dropHeld() }
    }

    /// Deallocation does what `destroy()` does. Loads in flight hold `self` for their duration, so none
    /// is running here; ads on screen are retained by `showing` and end with `.destroyed`.
    deinit {
        prefetch?.cancel()
        let slots = [overlay.slot, pause.slot, linear.slot]
        let teardown: @MainActor () -> Void = {
            for slot in slots {
                slot.pendingAd?.invalidate(.destroyed)
                slot.showing?.invalidate(.destroyed)
            }
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
        prefetch?.cancel()
        liveAds.forEach { $0.invalidate(.destroyed) }
        slots.values.forEach { slot in
            slot.showing?.invalidate(.destroyed)
            slot.clear()
        }
        Logger.debug("VideoAds destroyed for video \(content.id)")
    }
}
