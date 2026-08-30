import UIKit

/// The `pauseOverlay` placement of one video: an image banner shown over
/// part of the paused player.
@MainActor
public final class PauseOverlayAd {
    /// Where the banner sits inside the container.
    public enum Position: Sendable {
        case top
        case bottom
    }

    /// Appearance of the banner. Everything has a default.
    public struct Style: Sendable {
        /// Space between the banner and the container's safe-area edges.
        /// `top` applies for `.top`, `bottom` for `.bottom`; `left`/`right`
        /// always.
        public var margins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        /// Caps the banner width (centered) so it doesn't stretch across
        /// wide players such as iPad or landscape. `nil` = full width.
        public var maxWidth: CGFloat? = nil
        public var cornerRadius: CGFloat = 12
        /// Shown until the image has loaded.
        public var placeholderColor: UIColor = UIColor.black.withAlphaComponent(0.3)

        public init() {}
    }

    public let externalId: String

    /// Ads not yet shown, in the order the server returned them.
    public private(set) var pending: [VideoAd] = []

    /// Requests another ad for this placement only (one `/preload` with
    /// just this format). Same as `VideoAds.load(formats: [.pauseOverlay])`.
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
    private var view: PauseOverlayAdUIView?

    init(externalId: String, emit: @escaping (VideoAdEvent) -> Void) {
        self.externalId = externalId
        self.emit = emit
    }

    /// Shows the next ad as a banner inside `container` (typically the
    /// player view) and consumes it. Defaults to the top so the episode
    /// title most apps draw at the bottom stays visible.
    /// Returns `false` when ``isReady`` is `false`.
    @discardableResult
    public func show(in container: UIView, position: Position = .top, style: Style = Style()) -> Bool {
        guard isReady else { return false }
        let ad = pending.removeFirst()
        let view = PauseOverlayAdUIView(ad: ad, style: style)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onClick = { [weak self] in
            guard let self else { return }
            self.emit(.clicked(VideoAdEvent.AdData(format: .pauseOverlay, externalId: self.externalId)))
        }
        container.addSubview(view)
        let margins = style.margins
        var width = max(container.bounds.width - margins.left - margins.right, 0)
        if let maxWidth = style.maxWidth { width = min(width, maxWidth) }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: view.height(forWidth: width)),
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: (margins.left - margins.right) / 2),
            position == .top
                ? view.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: margins.top)
                : view.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -margins.bottom),
        ])
        view.alpha = 0
        UIView.animate(withDuration: 0.3) { view.alpha = 1 }
        self.view = view
        emit(.shown(VideoAdEvent.AdData(format: .pauseOverlay, externalId: externalId)))
        return true
    }

    /// Removes the banner if it is on screen. Call whenever playback
    /// resumes for any reason (tap, scrub, next episode).
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
