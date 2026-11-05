import AVFoundation
import Foundation
import UIKit

/// The ads of one video (one episode). Creating it sends nothing; every request comes from `format(_:)`.
/// Create the next episode's while the current one plays if you like; any number can be alive at once.
/// Call `destroy()` when the viewer leaves the video; releasing the object does the same, best effort, except
/// while a custom player passed to `track(_:)` references it (see there): then only `destroy()` does.
@MainActor
public final class VideoAds {
    /// The video these ads are for, as passed at creation; every request carries it.
    public let content: KontextVideo.Content
    /// `true` after `destroy()`: the object does nothing any more.
    public private(set) var isDestroyed = false
    /// The labels given at creation, exactly as given: what every request carries. A free format on purpose:
    /// Kontext defines them per publisher and the server ignores the ones it does not use, so the SDK sends what
    /// the app gives, with no checks (any key, any value, any number).
    let labels: [String: String]

    /// The content player set by `track(_:)`: the playhead, and the playing state an overlay follows.
    let playback = ContentPlayback()

    /// One per `VideoAds`, sent with every request: the server keeps the bids it gave out per session.
    let sessionId = UUID().uuidString.lowercased()
    /// The id of the latest ads request this object sent, `nil` before the first. Quote it to Kontext when an
    /// ad or a no-fill looks wrong: the server finds the request by it.
    public private(set) var lastRequestID: String?
    /// The unshown ads, the spent ids and the ad on screen.
    private(set) var store = AdStore()
    /// One ads request at a time, shared by every `format(_:)` meanwhile. Set once, at the end of `init`.
    private var fetcher: AdsFetcher?
    /// The system's memory warning. `nonisolated(unsafe)` only so `deinit`, which is not on the main actor,
    /// may read it for the teardown.
    nonisolated(unsafe) private var memoryWarningObserver: (any NSObjectProtocol)?

    /// Needs `initialize(with:)` to have been called; `/config` itself may still be in flight, requests
    /// wait for it. `labels`: key-values that say where these ads play, such as the viewer's stage in the
    /// series or the player's layout (`["stage": "first_episode", "layout": "fullscreen"]`). Every request
    /// of this object carries them, and the server's configuration decides what they change, such as which
    /// formats it offers; they are fixed for the object's life. They are sent as given: use the names and values
    /// Kontext gives you.
    /// They describe the screen, never the viewer: no personal data.
    public init(content: KontextVideo.Content, labels: [String: String] = [:]) {
        self.content = content
        self.labels = labels
        IntegrationGuard.requireInitialized("VideoAds(content:)")
        IntegrationGuard.checkContent(content, sessionId: sessionId)
        // An expired ad is otherwise dropped only at the next call; under memory pressure its renderer (the
        // WebView) is released at once. WebKit decides when its processes exit. Valid ads stay loaded: `show`
        // must stay instant.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropExpiredAds() }
        }
        // The ad on screen hears of the player: an overlay ends when the content stops, and counts its seconds;
        // a pause ad ends when the content plays again.
        playback.onChange = { [weak self] change in self?.store.showing?.contentRule.contentDidChange(change) }
        playback.isFollowerShown = { [weak self] in
            guard let ad = self?.store.showing else { return false }
            return ad.format != .linear && !ad.hasEnded
        }
        fetcher = AdsFetcher(owner: self)
        Logger.debug("VideoAds created for video \(content.id)")
    }

    /// Expired ads leave silently, as before a request (see `VideoAd.invalidate`).
    private func dropExpiredAds() {
        let expired = store.ads.values.filter { $0.descriptor.isExpired }
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
    /// ad when it is still valid. Throws `noFill(reason:)`, `request(_:)` (nothing valid held; its
    /// `RequestFailure` says why), `destroyed`, `disabled(reason:)`, `notInitialized`,
    /// `initializationFailed`, or `CancellationError` when the calling task is cancelled (the request
    /// itself continues).
    public func format(_ format: AdFormat) async throws -> VideoAd {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard IntegrationGuard.requireInitialized("ads.format(_:)") else { throw VideoAdError.notInitialized }
        guard let task = fetcher?.fetch() else { throw VideoAdError.destroyed }
        let noFill: AdsFetcher.NoFills
        do {
            noFill = try await awaitShared(task)
        } catch VideoAdError.request(let failure) {
            // Destroyed or switched off between the failure and this caller's turn: no held ad comes back.
            try checkStillUsable()
            if let held = validHeld(format) {
                Logger.info("\(format) for \(content.id): request failed, returning the held ad \(held.id.prefix(8))")
                return held
            }
            throw VideoAdError.request(failure)
        }
        try checkStillUsable()
        if let ad = validHeld(format) { return ad }
        throw VideoAdError.noFill(reason: noFill[format] ?? .unknown)
    }

    /// The held ad of `format` while it is valid. One that expired since the answer (app code ran before
    /// this caller resumed) leaves silently, as before a request.
    private func validHeld(_ format: AdFormat) -> VideoAd? {
        guard let held = store.ads[format] else { return nil }
        guard held.descriptor.isExpired else { return held }
        held.invalidate(.expired)
        return nil
    }

    /// The ids of the valid unshown ads, by format, for the request; expired ones leave silently first.
    func validHeldIds() -> [String] {
        for ad in Array(store.ads.values) where ad.descriptor.isExpired { ad.invalidate(.expired) }
        return AdFormat.allCases.compactMap { store.ads[$0]?.id }
    }

    /// Whether a valid unshown ad is held: what a failed request leaves the app with (an expired one is not).
    var holdsAds: Bool {
        store.ads.values.contains { !$0.descriptor.isExpired }
    }

    /// The request left with this id: the one `lastRequestID` names.
    func requestWasSent(_ requestId: String) {
        lastRequestID = requestId
    }

    /// `destroyed` after `destroy()`; `disabled` once any video's response switched the SDK off meanwhile.
    func checkStillUsable() throws {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        if let reason = KontextVideo.shared.disabledReason { throw VideoAdError.disabled(reason: reason) }
    }

    /// Follows the server for every format it answered, whatever the SDK's own clock says: the same id
    /// keeps the bid unchanged (the re-served payload is ignored); a new id replaces it, as does a no-fill,
    /// because the server replaces a held bid only once it expired. A format the answer leaves out decides
    /// nothing: its held ad stays as it is, loaded or not, until its own expiry (no held ad: a no-fill,
    /// reason unknown). An id the SDK already spent (shown or rejected while the request ran) is ignored
    /// for its format. A held ad that expired while the request ran leaves first, silently, whether the
    /// answer names its format or not. `AdStore.plan` decides each format; this carries the steps out.
    /// Returns the no-fill reasons by format.
    func follow(_ response: AdsResponse) -> AdsFetcher.NoFills {
        for ad in Array(store.ads.values) where ad.descriptor.isExpired { ad.invalidate(.expired) }
        var noFill: AdsFetcher.NoFills = [:]
        for step in store.plan(response) {
            switch step {
            case .keep:
                continue
            case .drop(let format):
                // Ending it takes it out of the store (`adDidLeave`).
                let held = store.ads[format]
                held?.invalidate(.expired)
            case .noFill(let format, let reason):
                noFill[format] = reason
                logNoFill(format, reason: reason)
            case .leftOut(let format):
                noFill[format] = .unknown
            case .ignoreUsed(let format, let id):
                Logger.debug("\(format) for \(content.id): ad \(id.prefix(8)) was already used, ignored")
                noFill[format] = .alreadyUsed
            case .replace(let format, let ad):
                Logger.info("\(format) for \(content.id): ad \(ad.id.prefix(8)), \(ad.price.value) \(ad.price.currency) cpm")
                DebugReporter.shared.event("ads.response", adId: ad.id, state: ["format": .string(format.rawValue), "filled": true])
                store.ads[format] = VideoAd(descriptor: AdDescriptor(payload: ad, receivedAt: Environment.now()), owner: self)
            }
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

    /// The player this episode plays in. The SDK reads its time for requests and the `[CONTENTPLAYHEAD]`
    /// macro of beacons, and follows its playback for an overlay and a pause ad: an overlay is shown over
    /// playing content only (`show(in:)` throws `contentPaused` otherwise), ends as `.interrupted` when the
    /// content pauses, ends or the player moves to another item, and its `duration` counts seconds of video
    /// (a pause in the background, where iOS pauses the player, freezes it instead: it goes on if the content
    /// plays again within a second of the app's return, and ends as `.interrupted` otherwise); a pause ad ends as `.interrupted` when the content plays again after a pause, whoever resumed it (the
    /// lock screen, Control Center, a headset, PiP or your own code). The SDK observes
    /// the player's `rate` and `currentItem`; it holds the player weakly (the app keeps it) and lets go at `destroy()`, after which `track` does nothing. With one
    /// `AVPlayer` reused across episodes, call it when this episode starts playing in it, not at creation:
    /// before that the player's time belongs to the previous episode. Without a player the playhead is 0
    /// (right for a prefetch), an overlay runs on its own time and a pause ad stays until it is closed or dismissed.
    ///
    /// Show an episode's ads only in that episode: an ad requested for it is counted for it. A player belongs
    /// to one `VideoAds` at a time: tracking it in another one lets go of it here, as if this one had never
    /// tracked a player (an overlay of it on screen ends as `.interrupted`), and from then on its overlay and
    /// pause ads throw `invalidated(.contentChanged)` at `show`, until this one tracks a player again. So do they
    /// once the `AVPlayer` moved to another item than the one it played at `track` (or, with none then, the
    /// first it got): another episode, or a looper's next loop. Linear ads are not checked: they cover the
    /// content. Without a tracked player nothing can be checked.
    public func track(_ player: AVPlayer) {
        guard !isDestroyed else { return }   // destroy() is terminal: nothing would release a new binding
        playback.track(player)
    }

    /// The same for any other player: conform it to `ContentPlayer`, or wrap it in a small type that does.
    /// Unlike an `AVPlayer`, it is held strongly, until `destroy()` or the next `track`: a wrapper needs no
    /// other reference. A player or wrapper that references this `VideoAds`, directly or through the object
    /// that owns it (your player model), makes a cycle: both stay alive, with the ads they hold and their
    /// WebViews, until `destroy()`. Call `destroy()` when the viewer leaves the video, as always, or keep
    /// the reference out of the adapter (or weak).
    ///
    /// Show an episode's ads only in that episode, as with an `AVPlayer`: the same object tracked by another
    /// `VideoAds` is let go of here, and this one's overlay and pause ads then throw
    /// `invalidated(.contentChanged)` at `show`. The SDK cannot see a custom player's item, so a wrapper reused
    /// across episodes is not checked for that: track it from each episode's `VideoAds` as it starts.
    public func track(_ player: some ContentPlayer) {
        guard !isDestroyed else { return }
        playback.track(player)
    }

    /// Content time in seconds, read now, or 0.
    var playhead: TimeInterval { playback.playhead }

    // MARK: What the ads report

    /// An ad ended before `show`, or was shown: it leaves its format, and its id is never accepted again.
    func adDidLeave(_ ad: VideoAd) {
        if store.ads[ad.format] === ad { store.ads[ad.format] = nil }
        store.spentIds.insert(ad.id)
    }

    /// Shown: the ad leaves its format, so the next request does not list it.
    func adDidBeginShowing(_ ad: VideoAd) {
        store.showing = ad
        // An overlay counts its seconds of video, and both it and a pause ad watch a player without a
        // publisher, on ticks. With no player tracked there is nothing to watch; a later `track` starts them.
        playback.isTicking = ad.format != .linear && playback.isTracking
        adDidLeave(ad)
    }

    func adDidEnd(_ ad: VideoAd) {
        guard store.showing === ad else { return }
        store.showing = nil
        playback.isTicking = false
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
        fetcher?.cancel()
        Self.endAll(Array(store.ads.values), showing: store.showing)
        store.ads = [:]
        store.showing = nil
        memoryWarningObserver.map(NotificationCenter.default.removeObserver)
        memoryWarningObserver = nil
        // After the last beacons read it: the player, its observers and the ticks go.
        playback.stop()
        Logger.debug("VideoAds destroyed for video \(content.id)")
    }

    /// Releasing the object does what `destroy()` does, best effort: the beacons leave if the process lives.
    /// Never reached while a tracked custom player references the object: `destroy()` breaks that cycle.
    /// Released while it still holds ads, it says so on the console: the usual cause is a `VideoAds` the app
    /// did not keep (a local variable, a SwiftUI view struct) while it kept the ads.
    deinit {
        let fetcher = self.fetcher
        let store = self.store
        let observer = memoryWarningObserver
        let playback = self.playback
        let contentId = content.id
        let teardown: @MainActor () -> Void = {
            fetcher?.cancel()
            if !store.ads.isEmpty {
                Logger.warning("VideoAds for video \(contentId) was released while holding \(store.ads.count) ad(s); they were ended as destroyed. Keep the VideoAds alive while you use its ads.")
            }
            VideoAds.endAll(Array(store.ads.values), showing: store.showing)
            observer.map(NotificationCenter.default.removeObserver)
            playback.stop()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            Task { @MainActor in teardown() }
        }
    }
}

extension VideoAds {
    /// `destroy()` and the release: every valid held ad gets its `notUsed` beacon and ends; the ad on screen ends.
    /// A held ad that expired meanwhile leaves silently, as everywhere else. Static, over copies: ending an ad
    /// calls back into its owner's store.
    static func endAll(_ ads: [VideoAd], showing: VideoAd?) {
        for ad in ads {
            if ad.descriptor.isExpired {
                ad.invalidate(.expired)
                continue
            }
            ad.tracker.withContentPlayhead {
                ad.invalidate(.destroyed)
                ad.tracker.fire("notUsed", notUsed: .destroyed)
            }
        }
        showing?.end(.destroyed)
    }
}
