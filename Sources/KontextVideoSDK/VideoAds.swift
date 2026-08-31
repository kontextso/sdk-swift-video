import UIKit

/// The ads of the current video — returned by
/// ``VideoSession/setVideo(id:title:description:duration:language:episodeNumber:series:)``.
///
/// One placement object per format. The app decides when ads are loaded
/// and shown; the SDK does not observe the player:
///
/// ```swift
/// let ads = session.setVideo(id: "ep-1042")
/// ads.load(formats: [.pause, .swipe, .overlay])
/// // on pause
/// if ads.pause.isReady { ads.pause.show(in: playerView) }
/// // on resume
/// ads.pause.hide()
/// ads.pause.load()                             // prepare the next one
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
    /// The publisher's unique video ID this handle belongs to.
    public let videoId: String
    public let title: String?
    public let description: String?
    /// Video length in seconds, when the app provided it.
    public let duration: TimeInterval?
    public let language: String?
    public let episodeNumber: Int?
    public let series: VideoSeries?

    /// Banner over part of the paused player.
    public let pause: PauseAd

    /// Full-screen video between two episodes.
    public let swipe: SwipeAd

    /// Image banners while the episode plays, in server-derived windows.
    public let overlay: OverlayAd

    /// `true` while a `/preload` request is in flight.
    public private(set) var isLoading = false

    /// `true` after ``destroy()``; the handle ignores `load` and `show`.
    public private(set) var isDestroyed = false

    private var loadTask: Task<Void, Never>?

    private weak var session: VideoSession?
    private let emit: (VideoAdEvent) -> Void

    init(
        videoId: String,
        title: String?,
        description: String?,
        duration: TimeInterval?,
        language: String?,
        episodeNumber: Int?,
        series: VideoSeries?,
        session: VideoSession,
        emit: @escaping (VideoAdEvent) -> Void
    ) {
        self.videoId = videoId
        self.title = title
        self.description = description
        self.duration = duration
        self.language = language
        self.episodeNumber = episodeNumber
        self.series = series
        self.session = session
        self.emit = emit
        self.pause = PauseAd(videoId: videoId, emit: emit)
        self.swipe = SwipeAd(videoId: videoId, emit: emit)
        self.overlay = OverlayAd(videoId: videoId, emit: emit)
        pause.loadHandler = { [weak self] in self?.load(formats: [.pause]) }
        swipe.loadHandler = { [weak self] in self?.load(formats: [.swipe]) }
        overlay.loadHandler = { [weak self] in self?.load(formats: [.overlay]) }
    }

    /// Requests ads for this video in one `/preload` call and appends them
    /// to the placements' `pending` queues. Emits one `.loaded` with a
    /// result row per requested format. Ignored while a request is already
    /// in flight.
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
        guard !isDestroyed, !isLoading, let session, session.isEnabled else { return }
        isLoading = true
        loadTask = Task {
            let outcome = await session.preload(self, formats: formats, playerSize: playerSize)
            isLoading = false
            guard !Task.isCancelled, !isDestroyed, outcome.succeeded else { return }
            let ads = outcome.ads
            pause.append(ads.filter { $0.format == .pause })
            swipe.append(ads.filter { $0.format == .swipe })
            overlay.append(ads.filter { $0.format == .overlay })
            let rows = formats.map { format -> VideoAdEvent.LoadedData.FormatResult in
                let served = ads.filter { $0.format == format }
                    .map { VideoAdEvent.LoadedData.FormatResult.Ad(id: $0.adId) }
                let server = outcome.results?.first { $0.format == format.rawValue }
                return VideoAdEvent.LoadedData.FormatResult(
                    format: format,
                    ads: served,
                    noFillReason: server?.noFillReason
                        ?? (served.isEmpty ? outcome.noFillReason : nil)
                )
            }
            emit(.loaded(VideoAdEvent.LoadedData(videoId: videoId, results: rows)))
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
        async let pauseAd: Void = pause.destroy()
        async let swipeAd: Void = swipe.destroy()
        async let playing: Void = overlay.destroy()
        _ = await (pauseAd, swipeAd, playing)
    }
}
