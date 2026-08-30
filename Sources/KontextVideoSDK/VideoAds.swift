import UIKit

/// The ads of the current video — returned by
/// ``VideoSession/setVideo(externalId:title:description:)``.
///
/// One placement object per format. The app decides when ads are loaded
/// and shown; the SDK does not observe the player:
///
/// ```swift
/// let ads = session.setVideo(externalId: "ep-1042")
/// ads.load(formats: [.pauseOverlay, .pauseFullscreen])
/// // on pause
/// if ads.pauseOverlay.isReady { ads.pauseOverlay.show(in: playerView) }
/// // on resume
/// ads.pauseOverlay.hide()
/// ads.pauseOverlay.load()                      // prepare the next one
/// ```
///
/// Each ad is shown once; `show` consumes it. Load again to prepare
/// another — whether one is served is the server's decision.
///
/// When the viewer leaves the video, `await ads.destroy()` (or just call
/// `setVideo` for the next one, which destroys the previous handle for
/// you).
@MainActor
public final class VideoAds {
    /// The publisher's video ID this handle belongs to.
    public let externalId: String
    public let title: String?
    public let description: String?

    /// Banner over part of the paused player.
    public let pauseOverlay: PauseOverlayAd

    /// Image over the whole paused player, with a Resume button.
    public let pauseFullscreen: PauseFullscreenAd

    /// Full-screen video between two episodes.
    public let swipe: SwipeAd

    /// `true` while a `/preload` request is in flight.
    public private(set) var isLoading = false

    /// `true` after ``destroy()``; the handle ignores `load` and `show`.
    public private(set) var isDestroyed = false

    private var loadTask: Task<Void, Never>?

    private weak var session: VideoSession?
    private let emit: (VideoAdEvent) -> Void

    init(
        externalId: String,
        title: String?,
        description: String?,
        session: VideoSession,
        emit: @escaping (VideoAdEvent) -> Void
    ) {
        self.externalId = externalId
        self.title = title
        self.description = description
        self.session = session
        self.emit = emit
        self.pauseOverlay = PauseOverlayAd(externalId: externalId, emit: emit)
        self.pauseFullscreen = PauseFullscreenAd(externalId: externalId, emit: emit)
        self.swipe = SwipeAd(externalId: externalId, emit: emit)
        pauseOverlay.loadHandler = { [weak self] in self?.load(formats: [.pauseOverlay]) }
        pauseFullscreen.loadHandler = { [weak self] in self?.load(formats: [.pauseFullscreen]) }
        swipe.loadHandler = { [weak self] in self?.load(formats: [.swipe]) }
    }

    /// Requests ads for this video in one `/preload` call and appends them
    /// to the placements' `pending` queues. Emits `.filled` / `.noFill`
    /// per requested format. Ignored while a request is already in flight.
    ///
    /// - Parameters:
    ///   - formats: Which placements to fill. Must not be empty — only what
    ///     you list is requested.
    ///   - playerSize: The player's size in pixels, when known, so the
    ///     server can pick a creative that fits.
    public func load(formats: [VideoAdFormat], playerSize: CGSize? = nil) {
        guard !formats.isEmpty else {
            assertionFailure("VideoAds.load(formats:) called with an empty list — name the formats you want")
            return
        }
        guard !isDestroyed, !isLoading, let session else { return }
        isLoading = true
        loadTask = Task {
            let outcome = await session.preload(self, formats: formats, playerSize: playerSize)
            isLoading = false
            guard !Task.isCancelled, !isDestroyed, outcome.succeeded else { return }
            let ads = outcome.ads
            pauseOverlay.append(ads.filter { $0.format == .pauseOverlay })
            pauseFullscreen.append(ads.filter { $0.format == .pauseFullscreen })
            swipe.append(ads.filter { $0.format == .swipe })
            for format in formats {
                if let ad = ads.first(where: { $0.format == format }) {
                    emit(.filled(VideoAdEvent.AdData(format: format, externalId: externalId, bidId: ad.bidId)))
                } else {
                    emit(.noFill(VideoAdEvent.NoFillData(format: format, externalId: externalId, reason: outcome.noFillReason)))
                }
            }
        }
    }

    /// Releases everything for this video: cancels an in-flight load,
    /// finishes measurement, removes ad views, and drops pending ads.
    /// Returns once the views are gone. When an ad was on screen this
    /// takes about a second (`Constants.teardownDelay`) so measurement
    /// scripts can send their final beacons; otherwise it returns
    /// immediately. Idempotent.
    public func destroy() async {
        guard !isDestroyed else { return }
        isDestroyed = true
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        async let overlay: Void = pauseOverlay.destroy()
        async let fullscreen: Void = pauseFullscreen.destroy()
        async let swipeAd: Void = swipe.destroy()
        _ = await (overlay, fullscreen, swipeAd)
    }
}
