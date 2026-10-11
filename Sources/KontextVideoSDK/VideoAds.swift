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

    public let content: KontextVideo.Content
    /// The size of the player, in points, as given at creation; `nil` means full screen.
    public let playerSize: CGSize?
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
    private weak var trackedPlayer: AVPlayer?

    /// The placement objects handed out, by format and id: the same typed lookup gives the same object.
    /// The one-ad-at-a-time state lives in this class keyed by id alone, so two typed handles for one id
    /// share it; whichever format is wrong hears it from the server (`invalidPlacement`).
    private var placements: [String: AnyObject] = [:]

    /// One unshown ad per placement at a time: the ad each placement handed out last, while the app keeps
    /// it. An ad on screen does not count; the next one may load while it shows.
    private var current: [String: WeakAd] = [:]
    /// Ads on screen, retained from `show` until `didEnd` so dropping the app's reference cannot abort them.
    private var showing: [String: VideoAd] = [:]
    /// Timed mode: the content time (ms) at which the server recommends the placement's next request.
    /// A recommendation, not a rule: an earlier `load` is an ordinary request.
    private(set) var nextRequestAt: [String: Int] = [:]
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
        if loading.contains(id) || current[id]?.value?.isPendingUnshown == true {
            Logger.warning("\(id) for \(content.id): load refused, the placement has an ad loading or loaded and not yet shown")
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
                                      player: .make(playerSize: playerSize, playheadMs: playheadMs), format: format)
        Logger.debug("\(id) for \(content.id): requesting \(format.format) at playhead \(request.player.playhead ?? 0) ms")
        DebugReporter.shared.event("ads.request", state: ["placementId": .string(id), "format": .string(format.format.rawValue), "playhead": .number(Double(request.player.playhead ?? 0))])

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
            // The page starts loading now; `load` returns only when it reported `ad.loaded`.
            let videoAd = VideoAd(ad: ad)
            videoAd.owner = self
            current[id] = WeakAd(videoAd)
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try await videoAd.awaitLoaded()
            } catch {
                current[id] = nil
                DebugReporter.shared.event("ad.loadFailed", adId: ad.id, level: "warning", state: ["reason": .string("\(error)")])
                throw error
            }
            guard !isDestroyed else { throw VideoAdError.destroyed }
            let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            Logger.info("\(id) for \(content.id): ad \(ad.id.prefix(8)) ready in \(durationMs) ms")
            DebugReporter.shared.event("ad.loaded", adId: ad.id, state: ["durationMs": .number(Double(durationMs))])
            return videoAd
        case .noFill(let reason, _, let next):
            nextRequestAt[id] = next
            Logger.info("\(id) for \(content.id): no fill (\(reason))\(next.map { ", next request at \($0) ms" } ?? "")")
            DebugReporter.shared.event("ads.response", state: ["placementId": .string(id), "filled": false, "reason": .string(reason)])
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
        let ads = liveAds.filter(\.isPendingUnshown)
        guard !ads.isEmpty else { return }
        Logger.debug("\(content.id): discarding \(ads.count) loaded ad(s), \(reason)")
        ads.forEach { $0.invalidate(.targetingChanged) }
    }

    /// Deallocation does what `destroy()` does. Loads in flight hold `self` for their duration, so none
    /// is running here; ads on screen are retained by `showing` and end with `.destroyed`.
    deinit {
        let showing = Array(self.showing.values)
        let loaded = current.values.compactMap(\.value)
        guard !showing.isEmpty || !loaded.isEmpty else { return }
        let teardown: @MainActor () -> Void = {
            loaded.forEach { $0.invalidate(.destroyed) }
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
