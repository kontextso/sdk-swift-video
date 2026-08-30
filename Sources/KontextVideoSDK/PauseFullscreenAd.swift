import UIKit

/// The `pauseFullscreen` placement of one video: an image over the whole
/// paused player with a Resume button. The button is the way out, because
/// the ad covers the app's own controls; its look is set via ``Style``.
@MainActor
public final class PauseFullscreenAd {
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

    public let externalId: String

    /// Ads not yet shown, in the order the server returned them.
    public private(set) var pending: [VideoAd] = []

    /// Requests another ad for this placement only (one `/preload` with
    /// just this format). Same as `VideoAds.load(formats: [.pauseFullscreen])`.
    public func load() {
        loadHandler?()
    }

    var loadHandler: (() -> Void)?

    /// `true` when an ad is loaded and none is on screen.
    public var isReady: Bool {
        !isDestroyed && view == nil && !pending.isEmpty
    }

    public private(set) var isDestroyed = false

    private let emit: (VideoAdEvent) -> Void
    private var view: PauseFullscreenAdUIView?

    init(externalId: String, emit: @escaping (VideoAdEvent) -> Void) {
        self.externalId = externalId
        self.emit = emit
    }

    /// Shows the next ad over the whole `container` (typically the player
    /// view) and consumes it. Returns `false` when ``isReady`` is `false`.
    ///
    /// - Parameter onResume: Called when the user taps Resume. The ad hides
    ///   itself first; resume playback here.
    @discardableResult
    public func show(in container: UIView, style: Style = Style(), onResume: @escaping () -> Void) -> Bool {
        guard isReady else { return false }
        let ad = pending.removeFirst()
        let view = PauseFullscreenAdUIView(ad: ad, style: style)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onClick = { [weak self] in
            guard let self else { return }
            self.emit(.clicked(VideoAdEvent.AdData(format: .pauseFullscreen, externalId: self.externalId, bidId: ad.bidId)))
        }
        view.onResume = { [weak self] in
            guard let self else { return }
            self.hide()
            self.emit(.closed(VideoAdEvent.AdData(format: .pauseFullscreen, externalId: self.externalId, bidId: ad.bidId)))
            onResume()
        }
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view.alpha = 0
        UIView.animate(withDuration: 0.3) { view.alpha = 1 }
        self.view = view
        emit(.shown(VideoAdEvent.AdData(format: .pauseFullscreen, externalId: externalId, bidId: ad.bidId)))
        return true
    }

    /// Removes the ad if it is on screen. Call whenever playback resumes
    /// for any reason other than the Resume button (scrub, next episode).
    public func hide() {
        view?.removeFromSuperview()
        view = nil
    }

    /// Tears the placement down: finishes measurement for an ad on screen,
    /// keeps its view alive for `Constants.teardownDelay`, then removes it
    /// and drops pending ads. Called by `VideoAds.destroy()`.
    func destroy() async {
        guard !isDestroyed else { return }
        isDestroyed = true
        pending.removeAll()
        guard let view else { return }
        view.isUserInteractionEnabled = false
        // OM session finish + final tracking pings go here.
        try? await Task.sleep(nanoseconds: UInt64(Constants.teardownDelay * 1_000_000_000))
        view.removeFromSuperview()
        if self.view === view { self.view = nil }
    }

    func append(_ ads: [VideoAd]) {
        guard !isDestroyed else { return }
        pending += ads
    }
}
