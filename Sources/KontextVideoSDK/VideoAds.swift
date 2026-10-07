import Foundation

/// The ads of one video. Created with `KontextVideo.shared.createVideoAds(for:player:)`; any number
/// can be alive at once, for example the next episode's while the current one plays.
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

    /// One ad per format at a time.
    private(set) var loaded: [AdFormat: LoadedAd] = [:]
    /// Timed mode: content time before which a format must not be requested again.
    private(set) var nextRequestAt: [AdFormat: Int] = [:]
    private var loading: [AdFormat: Task<Void, Never>] = [:]

    init(video: Video, player: Player) {
        self.video = video
        self.player = player
        Logger.debug("VideoAds created for video \(video.id)")
    }

    /// Requests an ad for every format. Each request waits for `/init` when that is still in flight.
    public func load() {
        load(.overlay(nil))
        load(.pause(nil))
        load(.interstitial(nil))
    }

    func load(_ format: FormatRequest) {
        guard !isDestroyed, KontextVideo.shared.requireInitialized("load()") else { return }
        let kind = format.format
        if let current = loaded[kind], !current.isExpired {
            Logger.debug("\(kind) for \(video.id): an ad is already loaded")
            return
        }
        if let at = nextRequestAt[kind], (player.playhead ?? 0) < at {
            Logger.debug("\(kind) for \(video.id): next request at \(at) ms, playhead is \(player.playhead ?? 0)")
            return
        }
        guard loading[kind] == nil else { return }
        loading[kind] = Task {
            defer { loading[kind] = nil }
            guard await KontextVideo.shared.waitUntilEnabled() else {
                Logger.warning("\(kind) for \(video.id): not requested, the SDK is \(KontextVideo.shared.state)")
                return
            }
            guard !isDestroyed, let configuration = KontextVideo.shared.configuration else { return }
            let request = AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, video: video, player: player, format: format)
            Logger.debug("\(kind) for \(video.id): requesting at playhead \(request.player.playhead ?? 0) ms")
            handle(await send(request), format: kind)
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
            Logger.error("\(request.format) for \(video.id): request failed, \(error)")
            return nil
        } catch {
            return nil
        }
    }

    private func handle(_ response: AdsResponse?, format: AdFormat) {
        guard !isDestroyed, let response else { return }
        switch response {
        case .ad(let ad, let next):
            loaded[format] = LoadedAd(ad: ad, receivedAt: ProcessInfo.processInfo.systemUptime)
            nextRequestAt[format] = next
            Logger.info("\(format) for \(video.id): ad \(ad.id.prefix(8)) \(describe(ad.trigger)), \(ad.price.value) \(ad.price.currency) cpm\(next.map { ", next request at \($0) ms" } ?? "")")
        case .noFill(let reason, let retryAfter, let next):
            nextRequestAt[format] = next
            Logger.info("\(format) for \(video.id): no fill (\(reason))\(retryAfter.map { ", retry after \($0) ms" } ?? "")\(next.map { ", next request at \($0) ms" } ?? "")")
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
