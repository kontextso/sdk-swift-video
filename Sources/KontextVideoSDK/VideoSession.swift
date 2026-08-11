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
    private var player: AVPlayer?
    private let adsService: AdsService

    private var currentAds: VideoAds?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var hasStartedPlayback = false
    private var overlayView: OverlayAdUIView?
    private var overlayBidId: String?
    private var pauseAdView: FullScreenAdUIView?
    private var swipeBannerView: FullScreenAdUIView?

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
        detachPlayerObservers()
        hideOverlay()
        hidePauseAd()
        self.playerView = playerView
        self.player = player
        hasStartedPlayback = false
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.playbackStatusChanged(status) }
        }
    }

    private func detachPlayerObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
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
        currentAds = ads
        hideOverlay()
        hidePauseAd()
        switch options.adsSource {
        case .mock:
            loadMockAds(for: ads)
        case .server:
            Task {
                await requestAds(for: ads)
            }
        }
        return ads
    }

    // MARK: - Internal

    private func loadMockAds(for ads: VideoAds) {
        do {
            let slots = try MockAdsLoader.load()
            sessionId = slots.first?.sessionId ?? "mock-session"
            ads.apply(slots)
            log("/ads (mock) → \(slots.count) ad(s) for \(ads.externalId)")
            for slot in slots {
                log("  \(slot.format) @\(Self.timestamp(ms: slot.startMs))–\(slot.endMs.map(Self.timestamp(ms:)) ?? "-") \"\(slot.creative?.headline ?? "")\"")
                emit(.filled(VideoAdEvent.AdData(format: slot.format, externalId: ads.externalId)))
            }
        } catch {
            emit(.error(VideoAdEvent.ErrorData(externalId: ads.externalId, message: "\(error)")))
        }
    }

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
                    currentAds?.setCreative(ad.creative, forBidId: slot.bidId)
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

    // MARK: - Rendering

    private func tick(_ time: CMTime) {
        guard let ads = currentAds else { return }
        let ms = Int(CMTimeGetSeconds(time) * 1000)
        let active = ads.overlays.first { slot in
            slot.format == .overlay && ms >= slot.startMs && ms < (slot.endMs ?? .max)
        }
        if let active, let creative = creative(for: active, in: ads) {
            showOverlay(creative: creative, slot: active, externalId: ads.externalId)
        } else {
            hideOverlay()
        }
    }

    private func playbackStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            hasStartedPlayback = true
            hidePauseAd()
        case .paused:
            guard hasStartedPlayback, let ads = currentAds,
                  let slot = ads.overlays.first(where: { $0.format == .pauseAd }),
                  let creative = creative(for: slot, in: ads) else {
                return
            }
            showPauseAd(creative: creative, externalId: ads.externalId)
        default:
            break
        }
    }

    private func creative(for slot: InstreamAd, in ads: VideoAds) -> InstreamAdCreative? {
        slot.creative ?? ads.creatives[slot.bidId]
    }

    private func showOverlay(creative: InstreamAdCreative, slot: InstreamAd, externalId: String) {
        guard let playerView, overlayBidId != slot.bidId else { return }
        hideOverlay()
        let view = OverlayAdUIView(creative: creative)
        view.translatesAutoresizingMaskIntoConstraints = false
        playerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: playerView.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: playerView.trailingAnchor, constant: -16),
            slot.position == "top"
                ? view.topAnchor.constraint(equalTo: playerView.safeAreaLayoutGuide.topAnchor, constant: 16)
                : view.bottomAnchor.constraint(equalTo: playerView.safeAreaLayoutGuide.bottomAnchor, constant: -100),
        ])
        view.alpha = 0
        UIView.animate(withDuration: 0.3) { view.alpha = 1 }
        overlayView = view
        overlayBidId = slot.bidId
        emit(.shown(VideoAdEvent.AdData(format: .overlay, externalId: externalId)))
    }

    private func hideOverlay() {
        overlayView?.removeFromSuperview()
        overlayView = nil
        overlayBidId = nil
    }

    private func showPauseAd(creative: InstreamAdCreative, externalId: String) {
        guard let playerView, pauseAdView == nil else { return }
        let view = FullScreenAdUIView(creative: creative, style: .pauseAd)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onClose = { [weak self] in
            // Dismisses the ad only — the video stays paused.
            self?.hidePauseAd()
        }
        playerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: playerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
        ])
        view.alpha = 0
        UIView.animate(withDuration: 0.3) { view.alpha = 1 }
        pauseAdView = view
        emit(.shown(VideoAdEvent.AdData(format: .pauseAd, externalId: externalId)))
    }

    private func hidePauseAd() {
        pauseAdView?.removeFromSuperview()
        pauseAdView = nil
    }

    func presentSwipeBanner(for ads: VideoAds) {
        guard swipeBannerView == nil,
              let slot = ads.overlays.first(where: { $0.format == .swipeBanner }),
              let creative = creative(for: slot, in: ads),
              let host = playerView?.window ?? playerView else {
            return
        }
        let view = FullScreenAdUIView(creative: creative, style: .swipeBanner)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onClose = { [weak self] in
            self?.swipeBannerView?.removeFromSuperview()
            self?.swipeBannerView = nil
        }
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        view.alpha = 0
        UIView.animate(withDuration: 0.25) { view.alpha = 1 }
        swipeBannerView = view
        emit(.shown(VideoAdEvent.AdData(format: .swipeBanner, externalId: ads.externalId)))
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
