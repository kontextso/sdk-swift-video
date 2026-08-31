import UIKit

/// The `pause` placement of one video: an image banner shown over part of
/// the paused player.
@MainActor
public final class PauseAd: AdPlacement {
    public typealias Position = BannerPosition
    public typealias Style = BannerStyle

    private var position: Position = .top
    private var style = Style()

    init(videoId: String, emit: @escaping (VideoAdEvent) -> Void) {
        super.init(format: .pause, videoId: videoId, emit: emit)
    }

    /// Shows the next ad as a banner inside `container` (typically the
    /// player view) and consumes it. Defaults to the top so the episode
    /// title most apps draw at the bottom stays visible. Returns `false`
    /// when ``isReady`` is `false`.
    ///
    /// `container` is any `UIView` — the SDK mounts the ad as a subview and
    /// never assumes an `AVPlayer`. Pass the view that fills the video area
    /// and clips to it (e.g. `AVPlayerLayer`'s host view, or SJVideoPlayer's
    /// `player.view`), not the outer view controller's view, so the ad's
    /// insets land on the video rather than the whole screen.
    @discardableResult
    public func show(in container: UIView, position: Position = .top, style: Style = Style()) -> Bool {
        self.position = position
        self.style = style
        return present(in: container)
    }

    override func makeView(for ad: VideoAd) -> UIView {
        let view = BannerAdUIView(ad: ad, style: style)
        view.onClick = { [weak self] in self?.onClick() }
        view.onImageLoaded = { [weak self] in self?.onCreativeRendered() }
        view.onImageFailed = { [weak self] message in self?.onCreativeFailed("pause: \(message)") }
        return view
    }

    override func mount(_ view: UIView, in container: UIView) {
        guard let banner = view as? BannerAdUIView else { return }
        mountBanner(banner, in: container, position: position, style: style)
    }
}
