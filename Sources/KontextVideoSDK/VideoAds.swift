import Foundation

/// The ads of the current video — returned by
/// ``VideoSession/setVideo(externalId:title:description:)``.
///
/// One placement object per format. The app decides when ads are loaded
/// and shown; the SDK does not observe the player:
///
/// ```swift
/// let ads = session.setVideo(externalId: "ep-1042")
/// ads.load(formats: [.pauseOverlay])           // or omit for all formats
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
        pauseOverlay.loadHandler = { [weak self] in self?.load(formats: [.pauseOverlay]) }
        pauseFullscreen.loadHandler = { [weak self] in self?.load(formats: [.pauseFullscreen]) }
    }

    /// Requests ads for this video in one `/preload` call and appends them
    /// to the placements' `pending` queues. Emits `.filled` / `.noFill`
    /// per requested format. Ignored while a request is already in flight.
    ///
    /// - Parameter formats: Which placements to fill. Defaults to all.
    public func load(formats: [VideoAdFormat] = VideoAdFormat.allCases) {
        guard !isDestroyed, !isLoading, let session, !formats.isEmpty else { return }
        isLoading = true
        loadTask = Task {
            let ads = await session.preload(self, formats: formats)
            isLoading = false
            guard !Task.isCancelled, !isDestroyed else { return }
            pauseOverlay.append(ads.filter { $0.format == .pauseOverlay })
            pauseFullscreen.append(ads.filter { $0.format == .pauseFullscreen })
            for format in formats {
                let data = VideoAdEvent.AdData(format: format, externalId: externalId)
                emit(ads.contains { $0.format == format } ? .filled(data) : .noFill(data))
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
        _ = await (overlay, fullscreen)
    }
}
