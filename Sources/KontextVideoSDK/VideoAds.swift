import Foundation

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

    public let content: KontextVideo.Content
    /// The player the ads are shown in; held weakly, it is usually the view controller that owns this object.
    public private(set) weak var player: (any KontextVideoPlayer)?
    /// `true` after `start()`: this content is playing in the player and requests carry its playhead.
    public private(set) var isStarted = false
    /// `true` after `destroy()`: the object does nothing any more.
    public private(set) var isDestroyed = false

    /// The placement objects handed out, by format and id: the same typed lookup gives the same object.
    /// The one-ad-at-a-time state lives in this class keyed by id alone, so two typed handles for one id
    /// share it; whichever format is wrong hears it from the server (`invalidPlacement`).
    private var placements: [String: AnyObject] = [:]

    /// One ad per placement at a time: the ad each placement handed out last, while the app keeps it.
    private var current: [String: WeakAd] = [:]
    /// Ads on screen, retained from `show` until `didEnd` so dropping the app's reference cannot abort them.
    private var showing: [String: VideoAd] = [:]
    /// Timed mode: content time (ms) before which a placement must not be requested again.
    private(set) var nextRequestAt: [String: Int] = [:]
    /// Placements with a request in flight.
    private var loading: Set<String> = []

    /// `content` describes the video, `player` the area the ads are shown in. Needs `initialize(with:)`
    /// to have been called; `/init` itself may still be in flight, loads wait for it.
    public init(content: KontextVideo.Content, player: any KontextVideoPlayer) {
        self.content = content
        self.player = player
        KontextVideo.shared.register(self)
        Logger.debug("VideoAds created for video \(content.id)")
    }

    /// Call it when this content starts playing in the player. Before it, every request is a prefetch at
    /// content time 0 with the player's current size, which is what makes loading the next episode's ads
    /// while this one plays correct: the player's playhead belongs to the current episode. After it,
    /// requests and `[CONTENTPLAYHEAD]` use the live playhead.
    /// A no-op while this object is active; after another `VideoAds` on the same player displaced it,
    /// calling it again makes this one active and the other one a prefetcher again.
    public func start() {
        guard !isDestroyed, !isStarted else { return }
        if let player {
            KontextVideo.shared.stopOthers(playing: player, except: self)
        }
        isStarted = true
        Logger.debug("\(content.id): started")
    }

    /// Another `VideoAds` started on the same player: this one is no longer the content playing there,
    /// so its requests fall back to prefetch mode (content time 0).
    func stop(because other: VideoAds) {
        guard isStarted else { return }
        isStarted = false
        Logger.warning("\(content.id): stopped, \(other.content.id) started on the same player; destroy the previous content's VideoAds when you move on")
        // Nothing of this content may sit over the next one; loaded, unshown ads stay for a return.
        showing.values.forEach { $0.end(.interrupted) }
    }

    /// Content time in milliseconds as a request sends it: 0 until `start()`.
    var playheadMs: Int {
        guard isStarted, let player else { return 0 }
        return Int((player.playhead * 1000).rounded())
    }

    /// The overlay placement with this id, as created in the Kontext dashboard. Get it once and keep it.
    public func overlayPlacement(_ id: String) -> OverlayPlacement {
        placement(id) { OverlayPlacement(id: id, ads: self) }
    }

    /// The pause placement with this id, as created in the Kontext dashboard. Get it once and keep it.
    public func pausePlacement(_ id: String) -> PausePlacement {
        placement(id) { PausePlacement(id: id, ads: self) }
    }

    /// The interstitial placement with this id, as created in the Kontext dashboard. Get it once and keep it.
    public func interstitialPlacement(_ id: String) -> InterstitialPlacement {
        placement(id) { InterstitialPlacement(id: id, ads: self) }
    }

    /// One object per (format, id).
    private func placement<P: AnyObject>(_ id: String, make: () -> P) -> P {
        let key = "\(P.self):\(id)"
        if let placement = placements[key] as? P { return placement }
        let placement = make()
        placements[key] = placement
        return placement
    }

    /// Every ad this object handed out that the app still holds and that is not yet gone.
    private var liveAds: [VideoAd] {
        current.values.compactMap(\.value)
    }

    /// The player was deallocated: terminal for this object. Every loaded ad is invalidated; the warning
    /// is logged once.
    func playerIsGone() {
        if !playerGoneLogged {
            playerGoneLogged = true
            Logger.error("\(content.id): the KontextVideoPlayer was deallocated; create a new VideoAds with the new player")
        }
        liveAds.forEach { $0.invalidate(.playerUnavailable) }
    }

    private var playerGoneLogged = false

    func adDidBeginShowing(_ ad: VideoAd) {
        showing[ad.placementId] = ad
    }

    func adDidEnd(_ ad: VideoAd) {
        if showing[ad.placementId] === ad { showing[ad.placementId] = nil }
    }

    /// One request for one placement, run on the caller's task so cancelling that task cancels the request.
    /// Returns the ad, or throws: no fill, a failed request, a busy placement, an SDK that is not ready.
    /// Waits for `/init` when that is still in flight.
    func load(_ format: FormatRequest) async throws -> VideoAd {
        guard !isDestroyed else { throw VideoAdError.destroyed }
        guard KontextVideo.shared.requireInitialized("load()") else { throw VideoAdError.notInitialized }
        let id = format.placementId
        if loading.contains(id) || current[id]?.value?.occupiesPlacement == true {
            Logger.warning("\(id) for \(content.id): load refused, the placement is busy")
            throw VideoAdError.placementBusy
        }
        if let at = nextRequestAt[id], playheadMs < at {
            Logger.debug("\(id) for \(content.id): next request at \(at) ms, playhead is \(playheadMs)")
            throw VideoAdError.tooEarly(nextRequestAt: TimeInterval(at) / 1000)
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
        guard let player else {
            playerIsGone()
            throw VideoAdError.playerUnavailable
        }
        let request = AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, content: content,
                                      player: .read(from: player, started: isStarted), format: format)
        Logger.debug("\(id) for \(content.id): requesting \(format.format) at playhead \(request.player.playhead ?? 0) ms")

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
            // The page starts loading now; `load` returns only when it reported `ad.loaded`.
            let videoAd = VideoAd(ad: ad)
            videoAd.owner = self
            current[id] = WeakAd(videoAd)
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try await videoAd.awaitLoaded()
            } catch {
                current[id] = nil
                throw error
            }
            guard !isDestroyed else { throw VideoAdError.destroyed }
            Logger.info("\(id) for \(content.id): ad \(ad.id.prefix(8)) ready in \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms")
            return videoAd
        case .noFill(let reason, _, let next):
            nextRequestAt[id] = next
            Logger.info("\(id) for \(content.id): no fill (\(reason))\(next.map { ", next request at \($0) ms" } ?? "")")
            throw VideoAdError.noFill(reason: reason)
        case .disabled(let reason):
            KontextVideo.shared.disable(reason: reason)
            throw VideoAdError.disabled(reason: reason)
        }
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
                // `detail` reads "expected overlay, got interstitial" when the server names the dashboard's format.
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

    /// The spec's rule: when the viewer's data or consent changes, loaded ads that were not shown are
    /// dropped so the next request carries the new values.
    func discardLoadedAds(reason: String) {
        let ads = liveAds.filter(\.occupiesPlacement)
        guard !ads.isEmpty else { return }
        Logger.debug("\(content.id): discarding \(ads.count) loaded ad(s), \(reason)")
        ads.forEach { $0.invalidate(.targetingChanged) }
    }

    /// Releases the video's ads. Call it when the viewer leaves the video; deallocation does the same.
    /// Loads in flight fail with `destroyed`, ads the app still holds are invalidated. Terminal: placements
    /// the app kept, and any looked up afterwards, throw `destroyed` from `load`.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        liveAds.forEach { $0.invalidate(.destroyed) }
        showing.values.forEach { $0.invalidate(.destroyed) }
        showing.removeAll()
        current.removeAll()
        Logger.debug("VideoAds destroyed for video \(content.id)")
    }

    private func describe(_ trigger: AdPayload.Trigger) -> String {
        switch trigger {
        case .manual: return "manual"
        case .window(let from, let to): return "window \(from)–\(to) ms"
        }
    }
}
