import UIKit

/// The `pauseOverlay` placement of one video: an image banner shown over
/// part of the paused player.
@MainActor
public final class PauseOverlayAd: PausePlacement {
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

    private var position: Position = .top
    private var style = Style()

    init(externalId: String, emit: @escaping (VideoAdEvent) -> Void) {
        super.init(format: .pauseOverlay, externalId: externalId, emit: emit)
    }

    /// Shows the next ad as a banner inside `container` (typically the
    /// player view) after the server's reveal delay, and consumes it.
    /// Defaults to the top so the episode title most apps draw at the
    /// bottom stays visible. Returns `false` when ``isReady`` is `false`.
    @discardableResult
    public func show(in container: UIView, position: Position = .top, style: Style = Style()) -> Bool {
        self.position = position
        self.style = style
        return present(in: container)
    }

    override func makeView(for ad: VideoAd) -> UIView {
        let view = PauseOverlayAdUIView(ad: ad, style: style)
        view.onClick = { [weak self] in self?.onClick() }
        view.onImageLoaded = { [weak self] in self?.onImageLoaded() }
        return view
    }

    override func mount(_ view: UIView, in container: UIView) {
        guard let banner = view as? PauseOverlayAdUIView else { return }
        container.addSubview(view)
        let margins = style.margins
        var width = max(container.bounds.width - margins.left - margins.right, 0)
        if let maxWidth = style.maxWidth { width = min(width, maxWidth) }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: banner.height(forWidth: width)),
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: (margins.left - margins.right) / 2),
            position == .top
                ? view.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: margins.top)
                : view.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -margins.bottom),
        ])
    }
}
