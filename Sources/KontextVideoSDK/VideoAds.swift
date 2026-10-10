import Foundation

/// The ads of one video. Create it as early as you like, for example the next episode's while the
/// current one plays; any number can be alive at once. Call `destroy()` when the viewer leaves the video.
@MainActor
public final class VideoAds {
    /// An ad the server returned, kept until it is shown, expires or is discarded.
    struct LoadedAd {
        let ad: Ad
        /// `ProcessInfo.systemUptime` at receipt: `expires` counts from here, on a monotonic clock.
        let receivedAt: TimeInterval

        var isExpired: Bool {
            (ProcessInfo.processInfo.systemUptime - receivedAt) * 1000 >= Double(ad.expires)
        }
    }

    public let video: Video
    /// The player the ads are shown in; the requests describe its box and playhead.
    public let player: Player
    /// `true` after `destroy()`: the object does nothing any more.
    public private(set) var isDestroyed = false

    /// The placement objects handed out, by id: asking twice for the same id gives the same object,
    /// so its one-ad-at-a-time state is shared.
    private var placements: [String: AnyObject] = [:]

    /// One ad per placement at a time.
    private(set) var loaded: [String: LoadedAd] = [:]
    /// Timed mode: content time before which a placement must not be requested again.
    private(set) var nextRequestAt: [String: Int] = [:]
    private var loading: [String: Task<Void, Never>] = [:]

    /// `video` describes the content, `player` the area the ads are shown in. Needs `initialize(with:)`
    /// to have been called; `/init` itself may still be in flight, loads wait for it.
    public init(video: Video, player: Player) {
        self.video = video
        self.player = player
        KontextVideo.shared.register(self)
        Logger.debug("VideoAds created for video \(video.id)")
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

    /// One object per id. The same id asked for with another format is a bug in the app: the dashboard
    /// gives every placement exactly one format.
    private func placement<P: AnyObject>(_ id: String, make: () -> P) -> P {
        if let existing = placements[id] {
            if let placement = existing as? P { return placement }
            assertionFailure("KontextVideo: placement \"\(id)\" was already used with another format")
            Logger.error("placement \"\(id)\" was already used with another format; the dashboard gives a placement one format")
        }
        let placement = make()
        placements[id] = placement
        return placement
    }

    /// One request for one placement. Waits for `/init` when that is still in flight.
    func load(_ format: FormatRequest) {
        guard !isDestroyed, KontextVideo.shared.requireInitialized("load()") else { return }
        let id = format.placementId
        if let current = loaded[id], !current.isExpired {
            Logger.debug("\(id) for \(video.id): an ad is already loaded")
            return
        }
        if let at = nextRequestAt[id], (player.playhead ?? 0) < at {
            Logger.debug("\(id) for \(video.id): next request at \(at) ms, playhead is \(player.playhead ?? 0)")
            return
        }
        guard loading[id] == nil else { return }
        loading[id] = Task {
            defer { loading[id] = nil }
            guard await KontextVideo.shared.waitUntilEnabled() else {
                Logger.warning("\(id) for \(video.id): not requested, the SDK is \(KontextVideo.shared.state)")
                return
            }
            guard !isDestroyed, let configuration = KontextVideo.shared.configuration else { return }
            let request = AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, video: video, player: player, format: format)
            Logger.debug("\(id) for \(video.id): requesting \(format.format) at playhead \(request.player.playhead ?? 0) ms")
            handle(await send(request), placementId: id)
        }
    }

    /// Ads requests are not retried: a timeout counts as `temporaryError`, and the next request happens
    /// at the format's next natural moment.
    private func send(_ request: AdsRequest) async -> AdsResponse? {
        let client = APIClient(baseURL: request.adServerUrl)
        do {
            return try await client.post("video/ads", body: request)
        } catch let error as APIError {
            if case .transport(let urlError) = error, urlError.code == .cancelled { return nil }
            Logger.error("\(request.placementId) for \(video.id): request failed, \(error)")
            return nil
        } catch {
            return nil
        }
    }

    private func handle(_ response: AdsResponse?, placementId: String) {
        guard !isDestroyed, let response else { return }
        switch response {
        case .ad(let ad, let next):
            loaded[placementId] = LoadedAd(ad: ad, receivedAt: ProcessInfo.processInfo.systemUptime)
            nextRequestAt[placementId] = next
            Logger.info("\(placementId) for \(video.id): \(ad.format) ad \(ad.id.prefix(8)) \(describe(ad.trigger)), \(ad.price.value) \(ad.price.currency) cpm\(next.map { ", next request at \($0) ms" } ?? "")")
        case .noFill(let reason, let retryAfter, let next):
            nextRequestAt[placementId] = next
            Logger.info("\(placementId) for \(video.id): no fill (\(reason))\(retryAfter.map { ", retry after \($0) ms" } ?? "")\(next.map { ", next request at \($0) ms" } ?? "")")
        case .disabled(let reason):
            KontextVideo.shared.disable(reason: reason)
        }
    }

    /// The spec's rule: when the viewer's data or consent changes, loaded ads that were not shown are
    /// dropped so the next request carries the new values.
    func discardLoadedAds(reason: String) {
        guard !loaded.isEmpty else { return }
        Logger.debug("\(video.id): discarding \(loaded.count) loaded ad(s), \(reason)")
        loaded.removeAll()
    }

    /// Releases the video's ads. Call it when the viewer leaves the video. Nothing destroys a
    /// `VideoAds` for you, so destroy the previous episode's when you move on.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        loading.values.forEach { $0.cancel() }
        loading.removeAll()
        loaded.removeAll()
        Logger.debug("VideoAds destroyed for video \(video.id)")
    }

    private func describe(_ trigger: Ad.Trigger) -> String {
        switch trigger {
        case .manual: return "manual"
        case .window(let from, let to): return "window \(from)–\(to) ms"
        }
    }
}
