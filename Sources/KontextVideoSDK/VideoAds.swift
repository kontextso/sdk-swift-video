import UIKit

/// The ads prepared for one video — returned by
/// ``VideoSession/startVideo(externalId:title:description:)``.
///
/// The app decides when ads appear: call ``showPauseAd(in:)`` when playback
/// pauses and ``hidePauseAd()`` when it resumes. The SDK does not observe
/// the player.
@MainActor
public final class VideoAds {
    /// Where the pause-ad banner sits inside the container.
    public enum BannerPosition: Sendable {
        case top
        case bottom
    }

    /// The publisher's video ID this handle belongs to.
    public let externalId: String

    /// Ads prepared for this video. Empty until `/preload` returns.
    public private(set) var ads: [VideoAd] = []

    private let emit: (VideoAdEvent) -> Void
    private var pauseAdView: PauseAdUIView?

    init(externalId: String, emit: @escaping (VideoAdEvent) -> Void) {
        self.externalId = externalId
        self.emit = emit
    }

    /// Shows the pause ad as an image banner inside `container` (typically
    /// the player view). Defaults to the top so it does not cover the
    /// episode title most apps draw at the bottom. Returns `false` when
    /// there is nothing to show — no fill, `/preload` still in flight, or
    /// an ad already on screen.
    @discardableResult
    public func showPauseAd(in container: UIView, position: BannerPosition = .top) -> Bool {
        guard pauseAdView == nil,
              let ad = ads.first(where: { $0.format == .pauseAd }) else {
            return false
        }
        let view = PauseAdUIView(creative: ad.creative)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        let inset: CGFloat = 16
        let width = container.bounds.width - 2 * inset
        let edge: NSLayoutConstraint
        switch position {
        case .top:
            edge = view.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: inset)
        case .bottom:
            edge = view.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -inset)
        }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            edge,
            view.heightAnchor.constraint(equalToConstant: view.height(forWidth: max(width, 0))),
        ])
        view.alpha = 0
        UIView.animate(withDuration: 0.3) { view.alpha = 1 }
        pauseAdView = view
        emit(.shown(VideoAdEvent.AdData(format: .pauseAd, externalId: externalId)))
        return true
    }

    /// Removes the pause ad if it is on screen. Call whenever playback
    /// resumes for any reason (tap, scrub, next episode).
    public func hidePauseAd() {
        pauseAdView?.removeFromSuperview()
        pauseAdView = nil
    }

    func apply(_ ads: [VideoAd]) {
        self.ads = ads
    }
}
