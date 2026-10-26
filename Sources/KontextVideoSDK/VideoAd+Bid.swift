import Foundation

extension VideoAd {
    /// Why the app did not use a bid; the server tells the DSP.
    public enum RejectReason: Sendable, Equatable {
        /// The app does not use it, for any reason: the moment passed, the viewer left, the app's own choice.
        case notUsed
        /// Another network won the publisher's auction; `winningPrice` (CPM) and `winner` (the network, in
        /// the app's own words: `"AppLovin MAX"`, `"AdMob"`) when the app knows them. DSPs use both.
        case outbid(winningPrice: Double? = nil, winner: String? = nil)
    }

    /// The server's answer for one format, before anything is rendered: what `VideoAds.format(_:)` returns.
    /// Look at its facts (`price`, `size`, `duration`, ...), then `load()` it, or `reject()` it. A
    /// `VideoAds` holds at most one unshown bid per format; `format(_:)` returns the same one until it is
    /// shown, rejected or dropped.
    ///
    /// ```swift
    /// let pause = try await ads.format(.pause)
    /// if pause.price.value >= otherNetworkPrice {
    ///     pauseAd = try await pause.load()
    /// } else {
    ///     try pause.reject(.outbid(winningPrice: otherNetworkPrice))
    /// }
    /// ```
    @MainActor
    public final class Bid {
        /// The facts an app decides on before rendering. Where the ad goes and how big it is are the
        /// SDK's business at `show`; nothing of that is exposed.
        public var id: String { data.id }
        public var format: AdFormat { data.format }
        public var price: Price { data.price }
        /// Linear: the video's length. Overlay: how long the SDK keeps it on screen, `nil` when it stays
        /// until the app ends it. Pause: always `nil`. Seconds.
        public var duration: TimeInterval? { data.duration }

        /// Why the bid ended before it was shown, once it did; `load()`, `show` and `reject()` throw it.
        public private(set) var invalidationReason: InvalidationReason?

        /// The server's answer; its deadline counts from the first receipt, a re-serve does not move it.
        let data: AdData
        /// Fires the bid's beacons: `notUsed` before anything is rendered, the rest through the `VideoAd`.
        let tracker: Tracker
        /// The `VideoAds` that holds it.
        weak var owner: VideoAds?
        /// The ad `load()` is rendering or rendered. Released when the bid ends before `show`; after
        /// `show` the ad holds its bid, not the other way round.
        private(set) var ad: VideoAd?
        /// The load in flight, shared by every `load()` call: the second waits for the first.
        private var loading: Task<VideoAd, Error>?

        init(data: AdData, owner: VideoAds) {
            self.data = data
            self.owner = owner
            tracker = Tracker(adId: data.id, entries: data.tracking)
            tracker.contentPlayhead = { [weak owner] in owner?.playhead ?? 0 }
        }

        /// Renders the creative and returns the ad, ready to show. Calls made while a load runs share it and
        /// get the same ad or the same error; a call after it returns the same ad, nothing is rendered twice.
        /// Throws `creativeFailed(code:)` when the creative fails or does not report ready within 10 s of
        /// active time, `invalidated(.expired)` once the bid's lifetime ran out (before or during the load),
        /// `invalidated(.rejected)` after `reject()`, `destroyed`, `disabled(reason:)`, or
        /// `CancellationError` when the calling task is cancelled (the load itself continues).
        public func load() async throws -> VideoAd {
            try checkUsable()
            if let ad, loading == nil { return ad }
            let task = loading ?? startLoading()
            return try await awaitShared(task)
        }

        /// The app does not use the bid: the SDK sends the `notUsed` beacon (the server tells the DSP), drops
        /// the bid and releases its WebView. Works on a bid that is loading or loaded, until `show`; a `load()`
        /// in flight throws `invalidated(.rejected)`, a later `show` too. Synchronous and fire-and-forget.
        /// Throws `alreadyShown` after `show`, `invalidated(reason)` or `destroyed` when the bid already ended.
        public func reject(_ reason: RejectReason = .notUsed) throws {
            if ad?.wasShown == true { throw VideoAdError.alreadyShown }
            if let invalidationReason { throw Self.error(for: invalidationReason) }
            if data.isExpired {
                invalidate(.expired)
                throw VideoAdError.invalidated(.expired)
            }
            Logger.info("\(format) bid \(id.prefix(8)): rejected (\(reason))")
            tracker.fire("notUsed", notUsed: Tracker.NotUsed(reason))
            invalidate(.rejected)
        }

        /// The bid can still be loaded or shown; otherwise the error to throw.
        func checkUsable() throws {
            guard let owner, !owner.isDestroyed else { throw VideoAdError.destroyed }
            if let reason = KontextVideo.shared.disabledReason { throw VideoAdError.disabled(reason: reason) }
            if let invalidationReason { throw Self.error(for: invalidationReason) }
            if data.isExpired {
                invalidate(.expired)
                throw VideoAdError.invalidated(.expired)
            }
        }

        /// The load belongs to the bid, not to the caller: an unstructured task nobody cancels. Only
        /// `invalidate` stops it, by failing the ad's wait for the page.
        private func startLoading() -> Task<VideoAd, Error> {
            let ad = VideoAd(bid: self)
            self.ad = ad
            let task = Task { [weak self] () throws -> VideoAd in
                defer { self?.loading = nil }
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    try await ad.awaitLoaded()
                } catch VideoAdError.creativeFailed(let code) {
                    self?.invalidate(.creativeFailed(code: code))
                    DebugReporter.shared.event("ad.loadFailed", adId: ad.id, level: .warning, state: ["code": .number(Double(code))])
                    throw VideoAdError.creativeFailed(code: code)
                } catch {
                    // The bid ended meanwhile: say why in the order the app expects (destroyed, disabled, rejected, ...).
                    try self?.checkUsable()
                    throw error
                }
                guard let self else { throw VideoAdError.destroyed }
                // Expired while the page loaded: the result is dropped.
                try checkUsable()
                let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                Logger.info("\(format) bid \(id.prefix(8)): ready in \(durationMs) ms")
                DebugReporter.shared.event("ad.loaded", adId: id, state: ["durationMs": .number(Double(durationMs))])
                return ad
            }
            loading = task
            return task
        }

        /// The bid ends before `show`: it leaves its `VideoAds` (never served again), its WebView is
        /// released, a `load()` in flight throws. No beacon here: `reject` and `destroy` fire `notUsed`
        /// themselves, an expired bid is the server's to close, a failed creative already fired `error`.
        func invalidate(_ reason: InvalidationReason) {
            guard invalidationReason == nil, ad?.wasShown != true else { return }
            invalidationReason = reason
            Logger.debug("\(format) bid \(id.prefix(8)) ended before show: \(reason)")
            DebugReporter.shared.event("ad.invalidated", adId: id, state: ["reason": .string("\(reason)")])
            ad?.didInvalidate(reason)
            ad = nil
            owner?.bidDidEnd(self)
        }

        static func error(for reason: InvalidationReason) -> VideoAdError {
            reason == .destroyed ? .destroyed : .invalidated(reason)
        }
    }
}
