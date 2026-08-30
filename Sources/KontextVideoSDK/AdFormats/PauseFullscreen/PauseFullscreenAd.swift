import UIKit

/// The `pauseFullscreen` placement of one video: an image over the whole
/// paused player with a Resume button. The button is the way out, because
/// the ad covers the app's own controls; its look is set via ``Style``.
@MainActor
public final class PauseFullscreenAd: AdPlacement {
    /// Appearance of the fullscreen ad. Everything has a default.
    public struct Style: Sendable {
        public var backgroundColor: UIColor = .black
        public var resumeTitle: String = "Resume"
        public var resumeFont: UIFont = .systemFont(ofSize: 15, weight: .semibold)
        public var resumeTitleColor: UIColor = .white
        public var resumeBackgroundColor: UIColor = UIColor.white.withAlphaComponent(0.16)
        public var resumeCornerRadius: CGFloat = 12
        /// Distance of the Resume button from the container's bottom safe area.
        public var resumeBottomInset: CGFloat = 32

        public init() {}
    }

    private var style = Style()
    private var onResume: (() -> Void)?

    init(externalId: String, emit: @escaping (VideoAdEvent) -> Void) {
        super.init(format: .pauseFullscreen, externalId: externalId, emit: emit)
    }

    /// Shows the next ad over the whole `container` (typically the player
    /// view) after the server's reveal delay, and consumes it. Returns
    /// `false` when ``isReady`` is `false`.
    ///
    /// - Parameter onResume: Called when the user taps Resume. The ad hides
    ///   itself first; resume playback here.
    @discardableResult
    public func show(in container: UIView, style: Style = Style(), onResume: @escaping () -> Void) -> Bool {
        self.style = style
        self.onResume = onResume
        return present(in: container)
    }

    override func makeView(for ad: VideoAd) -> UIView {
        let view = PauseFullscreenAdUIView(ad: ad, style: style)
        view.onClick = { [weak self] in self?.onClick() }
        view.onImageLoaded = { [weak self] in self?.onCreativeRendered() }
        view.onResume = { [weak self] in
            guard let self else { return }
            let resume = self.onResume
            self.onUserDismiss()
            resume?()
        }
        return view
    }

    override func mount(_ view: UIView, in container: UIView) {
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
