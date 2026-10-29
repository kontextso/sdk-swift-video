import AVFoundation
import Foundation
import UIKit

/// The ads of one video (one episode). Creating it sends nothing; every request comes from `format(_:)`.
/// Create the next episode's while the current one plays if you like; any number can be alive at once.
/// Call `destroy()` when the viewer leaves the video; releasing the object does the same, best effort.
@MainActor
public final class VideoAds {
    /// The video these ads are for, as passed at creation; every request carries it.
    public let content: KontextVideo.Content
    /// `true` after `destroy()`: the object does nothing any more.
    public private(set) var isDestroyed = false

    /// Where the SDK reads the content playhead, in seconds, when it needs one: at a request, in the
    /// `[CONTENTPLAYHEAD]` macro of a beacon. For any player; for an `AVPlayer`,
    /// `trackPlayhead(of:)` sets it for you. Nothing set: 0, which is what a request made before the
    /// episode plays (a prefetch) should carry. Capture your objects weakly: the closure is kept until
    /// `destroy()`. Read once per SDK operation, before it changes anything; return the time, nothing more.
    public var playheadProvider: (() -> TimeInterval)?

    /// One per `VideoAds`, sent with every request: the server keeps the bids it gave out per session.
    let sessionId = UUID().uuidString.lowercased()
    /// The id of the latest ads request this object sent, `nil` before the first. Quote it to Kontext when an
    /// ad or a no-fill looks wrong: the server finds the request by it.
    public private(set) var lastRequestId: String?
    /// The unshown ads, the spent ids and the ad on screen; a reference so `deinit` can reach it.
    private let state = State()
    /// The request in flight: every `format(_:)` meanwhile waits for it instead of sending another.
    private var request: Task<[AdFormat: VideoAdError.NoFillReason], Error>?
    /// The system's memory warning. `nonisolated(unsafe)` only so `deinit`, which is not on the main actor,
    /// may read it for the teardown.
    nonisolated(unsafe) private var memoryWarningObserver: (any NSObjectProtocol)?

    /// Needs `initialize(with:)` to have been called; `/config` itself may still be in flight, requests
    /// wait for it.
    public init(content: KontextVideo.Content) {
        self.content = content
        KontextVideo.shared.requireInitialized("VideoAds(content:)")
        // What the publisher passed wrong, said once here rather than as a server 400 later. An empty id or
        // language makes every request fail: a programmer error, which stops a debug build. The rest is
        // metadata the request leaves out.
        let missing = content.missingRequired
        if !missing.isEmpty {
            Environment.assertionFailure("KontextVideo.Content: \(missing.joined(separator: ", "))")
            Logger.error("content \(content.id): \(missing.joined(separator: ", ")); the server will refuse its requests")
            ErrorReporter.shared.report(.badContent, stage: .integration, sessionId: sessionId, detail: missing.joined(separator: ","))
        }
        if !content.leftOut.isEmpty {
            Logger.warning("content \(content.id): \(content.leftOut.joined(separator: ", "))")
        }
        // An expired ad is otherwise dropped only at the next call; under memory pressure its renderer (the
        // WebView) is released at once. WebKit decides when its processes exit. Valid ads stay loaded: `show`
        // must stay instant.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropExpiredAds() }
        }
        Logger.debug("VideoAds created for video \(content.id)")
    }

    /// Expired ads leave silently, as before a request: the server knows `expires`.
    private func dropExpiredAds() {
        let expired = state.ads.values.filter { $0.descriptor.isExpired }
        guard !expired.isEmpty else { return }
        Logger.info("\(content.id): memory warning, \(expired.count) expired ad(s) released")
        for ad in expired { ad.invalidate(.expired) }
    }

    // MARK: Getting an ad

    /// The ad for one format: `try await ads.format(.pause)`, then its `price` and other facts, then
    /// `load()` or `reject()`. Every call asks the server for all formats and lists the unshown ads it holds
    /// (`held`); the server returns those unchanged until they expire, so the same ad (loaded or not) comes
    /// back, and ads for the other formats wait for their own `format(_:)` call. Calls made while a
    /// request runs share it (`async let` for several formats at once). A failed request returns the held
    /// ad when it is still valid. Throws `noFill(reason:)`, `request` (nothing valid held), `destroyed`,
    /// `disabled(reason:)`, `notInitialized`, `initializationFailed`, or `CancellationError` when the
    /// calling task is cancelled (the request itself continues).
    public func format(_ format: AdFormat) async throws -> VideoAd {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard KontextVideo.shared.requireInitialized("ads.format(_:)") else { throw VideoAdError.notInitialized }
        let task = request ?? startRequest()
        let noFill: [AdFormat: VideoAdError.NoFillReason]
        do {
            noFill = try await awaitShared(task)
        } catch VideoAdError.request(let error) {
            // Destroyed or switched off between the failure and this caller's turn: no held ad comes back.
            try checkStillUsable()
            if let held = state.ads[format], !held.descriptor.isExpired {
                Logger.info("\(format) for \(content.id): request failed, returning the held ad \(held.id.prefix(8))")
                return held
            }
            throw VideoAdError.request(error)
        }
        try checkStillUsable()
        if let ad = state.ads[format] { return ad }
        throw VideoAdError.noFill(reason: noFill[format] ?? .unknown)
    }

    /// Whether a valid unshown ad is held: what a failed request leaves the app with (an expired one is not).
    private var holdsAds: Bool {
        state.ads.values.contains { !$0.descriptor.isExpired }
    }

    /// `destroyed` after `destroy()`; `disabled` once any video's response switched the SDK off meanwhile.
    private func checkStillUsable() throws {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        if let reason = KontextVideo.shared.disabledReason { throw VideoAdError.disabled(reason: reason) }
    }

    /// The request belongs to the `VideoAds`, not to the caller: nobody cancels it but `destroy()` or the
    /// `VideoAds`' release. It holds its owner weakly and only between its waits, so releasing the object
    /// mid-request reaches `deinit`, which cancels it. Expired ads are dropped first (silently; the server
    /// knows `expires`), so `held` lists valid ones.
    private func startRequest() -> Task<[AdFormat: VideoAdError.NoFillReason], Error> {
        for ad in Array(state.ads.values) where ad.descriptor.isExpired { ad.invalidate(.expired) }
        let held = AdFormat.allCases.compactMap { state.ads[$0]?.id }
        let content = content
        let sessionId = sessionId
        let task = Task { [weak self] () throws -> [AdFormat: VideoAdError.NoFillReason] in
            defer { self?.request = nil }
            /// The owner, for one synchronous step; `destroyed` once it was destroyed or released.
            @MainActor func owner() throws -> VideoAds {
                guard let self, !self.isDestroyed else { throw VideoAdError.destroyed }
                return self
            }
            let enabled: Bool
            do {
                enabled = try await KontextVideo.shared.waitUntilEnabled()
            } catch {
                // Only `destroy()` or the release cancels the request: it stops waiting for `/config`, which goes on.
                throw VideoAdError.destroyed
            }
            // Destroyed while waiting: `destroyed`, whatever `/config` said meanwhile.
            _ = try owner()
            guard enabled else {
                Logger.warning("\(content.id): not requested, the SDK is \(KontextVideo.shared.state)")
                if let reason = KontextVideo.shared.disabledReason { throw VideoAdError.disabled(reason: reason) }
                throw VideoAdError.initializationFailed
            }
            guard let configuration = KontextVideo.shared.configuration else { throw VideoAdError.notInitialized }
            // The ATT dialog, when the publisher left it to the SDK, comes before the first ads request.
            let tracking: TrackingInfo
            do {
                tracking = try await TrackingInfo.current(requestAuthorization: configuration.requestTrackingAuthorization)
            } catch {
                // Its callers stop waiting for the dialog, which goes on.
                throw VideoAdError.destroyed
            }
            let playhead = try owner().playhead
            let body = await AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, tracking: tracking, content: content,
                                             player: .make(playhead: playhead), sessionId: sessionId, held: held)
            // Another video's response may have switched the SDK off during the dialog or the build: nothing leaves.
            try owner().checkStillUsable()
            try owner().lastRequestId = body.requestId
            Logger.debug("\(content.id): requesting at playhead \(body.player.playhead) ms, holding \(held.count)")
            DebugReporter.shared.event("ads.request", state: ["held": .number(Double(held.count)), "playhead": .number(Double(body.player.playhead))])

            let response: AdsResponse
            do {
                response = try await APIClient(baseURL: body.adServerURL).post("video/ads", body: body)
            } catch {
                try owner().checkStillUsable()
                Logger.error("\(content.id): request \(body.requestId) failed, \(error)")
                // Once per request, here in the request every caller shares, not once per waiting caller.
                let failure = ErrorReporter.RequestFailure(error)
                let decoding: Bool = (error as? APIError)?.isDecoding ?? false
                let recovery: ErrorReporter.Recovery = try owner().holdsAds ? .heldAdsKept : .noAd
                ErrorReporter.shared.report(decoding ? .adsDecodeFailed : .adsRequestFailed, stage: .request, requestId: body.requestId,
                                            sessionId: sessionId, failure: failure, recovery: recovery)
                throw VideoAdError.request(error)
            }
            return try owner().receive(response)
        }
        request = task
        return task
    }

    /// The answer, for a `VideoAds` still in use. The kill switch in it switches the whole SDK off and
    /// drops every ad, with no notices: the server knows. Switched off meanwhile by another video's
    /// response: the answer is dropped, the ads it carries are never held.
    private func receive(_ response: AdsResponse) throws -> [AdFormat: VideoAdError.NoFillReason] {
        if case .disabled(let reason) = response {
            KontextVideo.shared.disable(reason: reason)
            // The reason is never seen: load() and show throw `.disabled` first.
            for ad in Array(state.ads.values) { ad.invalidate(.destroyed) }
            throw VideoAdError.disabled(reason: reason)
        }
        try checkStillUsable()
        return apply(response)
    }

    /// Follows the server for every format, whatever the SDK's own clock says: the same id keeps the bid
    /// unchanged (the re-served payload is ignored); a new id replaces it, as does a no-fill, because the
    /// server replaces a held bid only once it expired. An id the SDK already spent (shown or rejected
    /// while the request ran) is ignored for its format. Returns the no-fill reasons by format.
    private func apply(_ response: AdsResponse) -> [AdFormat: VideoAdError.NoFillReason] {
        var noFill: [AdFormat: VideoAdError.NoFillReason] = [:]
        for format in AdFormat.allCases {
            let current = state.ads[format]
            guard let ad = response.result(for: format)?.ads.first else {
                current?.invalidate(.expired)
                let reason = response.result(for: format)?.noFillReason ?? .unknown
                noFill[format] = reason
                logNoFill(format, reason: reason)
                continue
            }
            // Re-served and still valid: kept unchanged, the payload is ignored.
            if let current, current.id == ad.id, !current.descriptor.isExpired { continue }
            // Replaced, no longer served, or re-served after it expired: it never comes back.
            current?.invalidate(.expired)
            if state.spentIds.contains(ad.id) {
                Logger.debug("\(format) for \(content.id): ad \(ad.id.prefix(8)) was already used, ignored")
                noFill[format] = .alreadyUsed
                continue
            }
            Logger.info("\(format) for \(content.id): ad \(ad.id.prefix(8)), \(ad.price.value) \(ad.price.currency) cpm")
            DebugReporter.shared.event("ads.response", adId: ad.id, state: ["format": .string(format.rawValue), "filled": true])
            state.ads[format] = VideoAd(descriptor: AdDescriptor(payload: ad, receivedAt: Environment.now()), owner: self)
        }
        return noFill
    }

    private func logNoFill(_ format: AdFormat, reason: VideoAdError.NoFillReason) {
        // `formatNotEnabled` is the dashboard, not the moment: say so, it is not "try again later".
        if reason == .formatNotEnabled {
            Logger.error("\(format) for \(content.id): no configuration for this format in the Kontext dashboard (\(reason))")
        } else {
            Logger.info("\(format) for \(content.id): no fill (\(reason))")
        }
        // A reason this SDK does not know is the server's free text: "other" leaves the device, the text does not.
        let knownReason: String
        if case .other = reason { knownReason = "other" } else { knownReason = reason.description }
        DebugReporter.shared.event("ads.response", state: ["format": .string(format.rawValue), "filled": false, "reason": .string(knownReason)])
    }

    // MARK: Playhead

    /// Reads the content playhead from this `AVPlayer` whenever the SDK needs one; the player is held
    /// weakly and `currentTime()` is read at that moment, no observer is attached. With one `AVPlayer`
    /// reused across episodes, call it when this episode starts playing in it, not at creation: before
    /// that the player's time belongs to the previous episode. Sets `playheadProvider`.
    public func trackPlayhead(of player: AVPlayer) {
        // `seconds` is NaN for an invalid or indefinite time; `playhead` turns that into 0.
        playheadProvider = { [weak player] in player?.currentTime().seconds ?? 0 }
    }

    /// Content time in seconds, read now: the provider's, or 0. Clamped to ten years: a broken provider
    /// (NaN, infinity, a huge number) must not crash the app when the request converts it to `Int`.
    var playhead: TimeInterval {
        guard let value = playheadProvider?(), value.isFinite else { return 0 }
        return min(max(0, value), 315_360_000)
    }

    // MARK: What the ads report

    /// An ad ended before `show`, or was shown: it leaves its format, and its id is never accepted again.
    func adDidLeave(_ ad: VideoAd) {
        if state.ads[ad.format] === ad { state.ads[ad.format] = nil }
        state.spentIds.insert(ad.id)
    }

    /// Shown: the ad leaves its format, so the next request does not list it.
    func adDidBeginShowing(_ ad: VideoAd) {
        state.showing = ad
        adDidLeave(ad)
    }

    func adDidEnd(_ ad: VideoAd) {
        if state.showing === ad { state.showing = nil }
    }

    // MARK: Destroying

    /// Releases the video's ads. Call it when the viewer leaves the video. Every valid held ad, loaded or
    /// not, is dropped with a `notUsed` beacon (`destroyed`) and its WebView released; one that expired leaves
    /// silently, as the server knows `expires`. `load()` and `show` on them throw `destroyed`; the ad on
    /// screen ends with `didEnd(.destroyed)`; a `format()` or `load()` in flight throws `destroyed`. Calling
    /// it twice does nothing; afterwards `format()` throws `destroyed`.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        request?.cancel()
        state.endAll()
        memoryWarningObserver.map(NotificationCenter.default.removeObserver)
        memoryWarningObserver = nil
        // After the last beacons read it: an app closure that captures what owns this object no longer keeps it.
        playheadProvider = nil
        Logger.debug("VideoAds destroyed for video \(content.id)")
    }

    /// Releasing the object does what `destroy()` does, best effort: the beacons leave if the process lives.
    /// Released while it still holds ads, it says so on the console: the usual cause is a `VideoAds` the app
    /// did not keep (a local variable, a SwiftUI view struct) while it kept the ads.
    deinit {
        let request = self.request
        let state = self.state
        let observer = memoryWarningObserver
        let contentId = content.id
        let teardown: @MainActor () -> Void = {
            request?.cancel()
            if !state.ads.isEmpty {
                Logger.warning("VideoAds for video \(contentId) was released while holding \(state.ads.count) ad(s); they were ended as destroyed. Keep the VideoAds alive while you use its ads.")
            }
            state.endAll()
            observer.map(NotificationCenter.default.removeObserver)
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
        /// The unshown ad of each format, at most one.
        var ads: [AdFormat: VideoAd] = [:]
        /// Ids that left: shown, rejected, expired, failed, destroyed. A response that brings one back is
        /// ignored for its format: the request listed the ad before the app used it.
        var spentIds: Set<String> = []
        /// The ad of this `VideoAds` on screen. `KontextVideo.adOnScreen` retains it too.
        var showing: VideoAd?

        /// `destroy()`: every valid held ad gets its `notUsed` beacon and ends; the ad on screen ends. A held ad
        /// that expired meanwhile leaves silently, as everywhere else: the server knows `expires`.
        func endAll() {
            for ad in Array(ads.values) {
                if ad.descriptor.isExpired {
                    ad.invalidate(.expired)
                    continue
                }
                ad.withContentPlayhead {
                    ad.invalidate(.destroyed)
                    ad.tracker.fire("notUsed", notUsed: .destroyed)
                }
            }
            ads = [:]
            showing?.end(.destroyed)
            showing = nil
        }
    }
}
