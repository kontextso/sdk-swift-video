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

    public let externalId: String

    /// Ads not yet shown, in the order the server returned them.
    public private(set) var pending: [VideoAd] = []

    /// `true` when an ad is loaded and none is on screen.
    public var isReady: Bool {
        view == nil && !pending.isEmpty
    }

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
    public func show(in container: UIView, position: Position = .top) -> Bool {
        guard isReady else { return false }
        let ad = pending.removeFirst()
        let view = PauseOverlayAdUIView(ad: ad)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onClick = { [weak self] in
            guard let self else { return }
            self.emit(.clicked(VideoAdEvent.AdData(format: .pauseOverlay, externalId: self.externalId)))
        }
        container.addSubview(view)
        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.heightAnchor.constraint(equalToConstant: view.height(forWidth: max(container.bounds.width - 2 * inset, 0))),
            position == .top
                ? view.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: inset)
                : view.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -inset),
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

    func apply(_ ads: [VideoAd]) {
        pending = ads
    }
}
