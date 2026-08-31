import UIKit

/// The `overlay` placement of one video: image banners shown **while the
/// episode plays**, several per video, each with a window the server
/// derived from the scene (`trigger.from_ms` … `to_ms`).
///
/// The SDK never touches the player. The app feeds it the playhead and is
/// *told* when a window opens or closes; showing is always the app's call:
///
/// ```swift
/// ads.overlay.onWindowOpen  = { ad in ads.overlay.show(in: playerView) }
/// ads.overlay.onWindowClose = { ad in ads.overlay.hide() }
/// player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { t in
///     ads.overlay.playhead = t.seconds
/// }
/// // any time, windows ignored:
/// if ads.overlay.isReady { ads.overlay.show(in: playerView) }
/// ```
///
/// Windows are hints: an ignored window leaves the ad in `pending` for a
/// later manual `show`. `show(in:)` prefers the ad whose window is open.
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

    /// Shows an overlay inside `container` and consumes it: the ad whose
    /// window is open if there is one, else the next pending ad. Position
    /// defaults to the server's `placement.position`, then `.bottom`.
    /// Returns `false` when ``isReady`` is `false`.
    @discardableResult
    public func show(in container: UIView, position: Position? = nil, style: Style = Style()) -> Bool {
        guard isReady else { return false }
        if let open = openWindowAd, let index = pending.firstIndex(where: { $0.bidId == open.bidId }), index != 0 {
            moveToFront(index)
        }
        self.position = position
        self.style = style
        return present(in: container)
    }

    /// Shows a specific pending ad (from ``onWindowOpen`` or ``pending``).
    @discardableResult
    public func show(_ ad: VideoAd, in container: UIView, position: Position? = nil, style: Style = Style()) -> Bool {
        guard let index = pending.firstIndex(where: { $0.bidId == ad.bidId }) else { return false }
        moveToFront(index)
        self.position = position
        self.style = style
        return present(in: container)
    }

    override func makeView(for ad: VideoAd) -> UIView {
        let view = BannerAdUIView(ad: ad, style: style)
        view.onClick = { [weak self] in self?.onClick() }
        view.onImageLoaded = { [weak self] in self?.onCreativeRendered() }
        return view
    }

    override func mount(_ view: UIView, in container: UIView) {
        guard let banner = view as? BannerAdUIView, let ad = current else { return }
        let position = position ?? Position(serverValue: ad.placement?.position) ?? .bottom
        mountBanner(banner, in: container, position: position, style: style)
    }

    private func evaluateWindows() {
        let ms = Int(playhead * 1000)
        func isOpen(_ ad: VideoAd) -> Bool {
            guard let from = ad.trigger.fromMs else { return false }
            return ms >= from && ms < (ad.trigger.toMs ?? Int.max)
        }
        // The ad on screen left `pending` when it was shown but keeps its
        // window; consider it first so its own window can't "close" it.
        let nowOpen = (current.map { [$0] } ?? []).first(where: isOpen) ?? pending.first(where: isOpen)
        if let open = openWindowAd, nowOpen?.bidId != open.bidId {
            openWindowAd = nil
            onWindowClose?(open)
        }
        if let nowOpen, openWindowAd?.bidId != nowOpen.bidId {
            openWindowAd = nowOpen
            if nowOpen.bidId != current?.bidId {
                onWindowOpen?(nowOpen)
            }
        }
    }
}
