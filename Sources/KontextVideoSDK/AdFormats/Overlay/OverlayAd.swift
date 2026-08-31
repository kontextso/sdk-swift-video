import UIKit

/// The `overlay` placement of one video: image banners shown **while the
/// episode plays**, several per video.
///
/// Two modes, decided by the server per ad:
///
/// **Windowed** (`trigger { kind: "range", from_ms, to_ms }`) — the server
/// knows the content and derived scene windows. The SDK never touches the
/// player: the app feeds it the playhead and is *told* when a window opens
/// or closes; showing is always the app's call:
///
/// ```swift
/// ads.overlay.onWindowOpen  = { ad in ads.overlay.show(in: playerView) }
/// ads.overlay.onWindowClose = { ad in ads.overlay.hide() }
/// player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { t in
///     ads.overlay.playhead = t.seconds
/// }
/// ```
///
/// **Manual** (`trigger { kind: "manual" }`) — the publisher shared no
/// content, so there are no windows; the app decides the moment, exactly
/// like the pause ad:
///
/// ```swift
/// if ads.overlay.isReady { ads.overlay.show(in: playerView) }
/// ads.overlay.hide()
/// ```
///
/// The modes mix: `show(in:)` prefers the ad whose window is open now,
/// then manual ads, then anything pending — so a manual `show` never
/// steals an ad the server scheduled for a later scene. Windows are hints;
/// an ignored window leaves the ad in `pending`.
@MainActor
public final class OverlayAd: AdPlacement {
    public typealias Position = BannerPosition
    public typealias Style = BannerStyle

    /// Current playback position of the episode, in seconds. Set it from
    /// your player's periodic time observer; the SDK compares it with the
    /// pending ads' windows and calls ``onWindowOpen`` / ``onWindowClose``.
    public var playhead: TimeInterval = 0 {
        didSet { evaluateWindows() }
    }

    /// A pending ad's window contains the playhead. Show it (or don't).
    public var onWindowOpen: ((VideoAd) -> Void)?

    /// The window of the ad on screen (or the last opened one) ended.
    /// Typically `hide()`.
    public var onWindowClose: ((VideoAd) -> Void)?

    /// The ad whose window is open right now, if any.
    public private(set) var openWindowAd: VideoAd?

    private var style = Style()
    private var position: Position?

    init(videoId: String, emit: @escaping (VideoAdEvent) -> Void) {
        super.init(format: .overlay, videoId: videoId, emit: emit)
    }

    /// Shows an overlay inside `container` and consumes it, preferring the
    /// ad whose window is open now, then manual (window-less) ads, then
    /// the next pending — so a manual show never steals an ad scheduled
    /// for a later scene. Position defaults to the server's
    /// `placement.position`, then `.bottom`. Returns `false` when
    /// ``isReady`` is `false`.
    ///
    /// `container` is any `UIView` — the SDK mounts the ad as a subview and
    /// never assumes an `AVPlayer`. Pass the view that fills the video area
    /// and clips to it (e.g. `AVPlayerLayer`'s host view, or SJVideoPlayer's
    /// `player.view`), not the outer view controller's view, so the ad's
    /// insets land on the video rather than the whole screen.
    @discardableResult
    public func show(in container: UIView, position: Position? = nil, style: Style = Style()) -> Bool {
        guard isReady else { return false }
        let preferred = openWindowAd ?? pending.first { $0.trigger.from == nil }
        if let preferred, let index = pending.firstIndex(where: { $0.adId == preferred.adId }), index != 0 {
            moveToFront(index)
        }
        self.position = position
        self.style = style
        return present(in: container)
    }

    /// Shows a specific pending ad (from ``onWindowOpen`` or ``pending``).
    @discardableResult
    public func show(_ ad: VideoAd, in container: UIView, position: Position? = nil, style: Style = Style()) -> Bool {
        guard let index = pending.firstIndex(where: { $0.adId == ad.adId }) else { return false }
        moveToFront(index)
        self.position = position
        self.style = style
        return present(in: container)
    }

    override func makeView(for ad: VideoAd) -> UIView {
        let view = BannerAdUIView(ad: ad, style: style)
        view.onClick = { [weak self] in self?.onClick() }
        view.onImageLoaded = { [weak self] in self?.onCreativeRendered() }
        view.onImageFailed = { [weak self] message in self?.onCreativeFailed("overlay: \(message)") }
        return view
    }

    override func mount(_ view: UIView, in container: UIView) {
        guard let banner = view as? BannerAdUIView, let ad = current else { return }
        let position = position ?? Position(serverValue: ad.placement?.position) ?? .bottom
        mountBanner(banner, in: container, position: position, style: style)
    }

    private func evaluateWindows() {
        let now = playhead
        func isOpen(_ ad: VideoAd) -> Bool {
            guard let from = ad.trigger.from else { return false }
            return now >= from && now < (ad.trigger.to ?? .infinity)
        }
        // The ad on screen left `pending` when it was shown but keeps its
        // window; consider it first so its own window can't "close" it.
        let nowOpen = (current.map { [$0] } ?? []).first(where: isOpen) ?? pending.first(where: isOpen)
        if let open = openWindowAd, nowOpen?.adId != open.adId {
            openWindowAd = nil
            onWindowClose?(open)
        }
        if let nowOpen, openWindowAd?.adId != nowOpen.adId {
            openWindowAd = nowOpen
            if nowOpen.adId != current?.adId {
                onWindowOpen?(nowOpen)
            }
        }
    }
}
