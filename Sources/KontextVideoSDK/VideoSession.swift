import AVFoundation
import UIKit

/// One instance per app user. Owns the connection to the ad server,
/// the attached player, and the per-video ad lifecycle.
///
/// Lifecycle:
/// 1. Create via ``KontextVideo/createSession(_:)``.
/// 2. Attach the publisher's player with ``attachPlayer(playerView:player:)``
///    so the SDK can render ads over it (overlay, pause ad) and observe
///    playback state.
/// 3. Call ``startVideo(externalId:title:description:)`` every time a new
///    video starts loading. This preloads ads for all enabled formats and
///    returns a ``VideoAds`` handle for that video.
@MainActor
public final class VideoSession {
    public let options: VideoSessionOptions

    /// Persistent install ID, generated on first launch.
    let installId: String

    /// Viewing-session ID assigned by the server on the first preload
    /// response. Empty until then; sent with every subsequent request.
    private(set) var sessionId: String = ""

    private weak var playerView: UIView?
    private weak var player: AVPlayer?
    private let adsService: AdsService

    init(options: VideoSessionOptions) {
        self.options = options
        self.installId = InstallID.current
        self.adsService = AdsService(adServerURL: options.adServerURL)
    }

    /// Attaches the publisher's player so the SDK can render ads over it
    /// (overlay, pause ad) and react to playback state (pause detection).
    ///
    /// Player integrations differ per publisher; this AVPlayer-based entry
    /// point is the baseline and will grow richer variants as design
    /// partners need them.
    public func attachPlayer(playerView: UIView, player: AVPlayer) {
        self.playerView = playerView
        self.player = player
        // TODO: observe player state (pause/resume/end) to drive pause ads.
    }

    /// Tells the SDK a new video is loading. Fires the ads request for the
    /// whole video and returns the handle holding the ads prepared for this
    /// video (not the video itself).
    ///
    /// Current wiring: calls the existing `GET /instream/vmap` (aka
    /// `GET /v1/ads`) endpoint with the parameters it supports today, parses
    /// the VMAP playlist, fetches each ad's JSON creative, and logs
    /// everything to the console. Rendering comes next.
    ///
    /// - Parameters:
    ///   - externalId: The publisher's own video ID. **Temporary caveat:**
    ///     the server has no external-id resolution yet, so until it does
    ///     this must be a Kontext `title_id` of an analyzed video.
    ///   - title: Optional if the video was uploaded via the API. Otherwise
    ///     it is the main content context the server gets. (Not yet sent —
    ///     the current endpoint has no parameter for it.)
    ///   - description: Same as `title`.
    public func startVideo(
        externalId: String,
        title: String? = nil,
        description: String? = nil
    ) -> VideoAds {
        let ads = VideoAds(externalId: externalId, session: self)
        Task {
            await requestAds(for: ads)
        }
        return ads
    }

    // MARK: - Internal

    private func requestAds(for ads: VideoAds) async {
        do {
            let slots = try await adsService.fetchAds(
                publisherToken: options.publisherToken,
                titleId: ads.externalId,
                userId: options.userId,
                playerSize: playerSize,
                maxSlots: nil
            )
            if let newSessionId = slots.first(where: { $0.sessionId != nil })?.sessionId {
                sessionId = newSessionId
            }
            ads.apply(slots)
            log("/ads → \(slots.count) ad(s) for title \(ads.externalId), session \(sessionId)")
            if slots.isEmpty {
                emit(.noFill(VideoAdEvent.AdData(format: .overlay, externalId: ads.externalId)))
                return
            }
            for slot in slots {
                log("  slot \(slot.index) @\(Self.timestamp(ms: slot.startMs))–\(slot.endMs.map(Self.timestamp(ms:)) ?? "?") position=\(slot.position ?? "?") size=\(slot.width ?? 0)x\(slot.height ?? 0) bid=\(slot.bidId)")
                emit(.filled(VideoAdEvent.AdData(format: .overlay, externalId: ads.externalId)))
            }
            await logCreatives(for: slots)
        } catch {
            emit(.error(VideoAdEvent.ErrorData(externalId: ads.externalId, message: "\(error)")))
        }
    }

    /// Ad copy is written asynchronously on the server, so the JSON creative
    /// can 404 for a few seconds after the ads response — retry briefly.
    private func logCreatives(for slots: [InstreamAd]) async {
        for slot in slots {
            guard let url = slot.adJsonURL else { continue }
            for attempt in 1...3 {
                do {
                    let ad = try await adsService.fetchCreative(adJsonURL: url)
                    log("  creative \(slot.index) [\(ad.format)] \"\(ad.creative.headline)\" — \(ad.creative.body.prefix(80))… CTA: \(ad.creative.cta.text)")
                    break
                } catch {
                    if attempt == 3 {
                        log("  creative \(slot.index) not ready after \(attempt) attempts (\(error))")
                    } else {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
            }
        }
    }

    private var playerSize: (width: Int, height: Int)? {
        guard let playerView, playerView.bounds.width > 0 else { return nil }
        let scale = playerView.window?.screen.scale ?? 1
        return (Int(playerView.bounds.width * scale), Int(playerView.bounds.height * scale))
    }

    private static func timestamp(ms: Int) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d.%03d", seconds / 60, seconds % 60, ms % 1000)
    }

    private func log(_ message: String) {
        print("[KontextVideoSDK] \(message)")
    }

    func emit(_ event: VideoAdEvent) {
        options.onEvent?(event)
    }
}
