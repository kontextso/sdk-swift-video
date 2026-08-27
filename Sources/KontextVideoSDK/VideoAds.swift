import UIKit

/// The ads prepared for one video — returned by
/// ``VideoSession/startVideo(externalId:title:description:)``.
///
/// The app decides when ads appear: call ``showPauseAd(in:onResume:)`` when
/// playback pauses and ``hidePauseAd()`` when it resumes. The SDK does not
/// observe the player.
@MainActor
public final class VideoAds {
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

    /// Shows the pause ad over `container` (typically the player view).
    /// Returns `false` when there is nothing to show — no fill, `/preload`
    /// still in flight, or an ad already on screen.
    ///
    /// - Parameter onResume: Called when the user taps the ad's Resume
    ///   button. Resume playback there; the ad hides itself first.
    @discardableResult
    public func showPauseAd(in container: UIView, onResume: @escaping () -> Void) -> Bool {
        guard pauseAdView == nil,
              let ad = ads.first(where: { $0.format == .pauseAd }) else {
            return false
        }
        let view = PauseAdUIView(creative: ad.creative)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onResume = { [weak self] in
            self?.hidePauseAd()
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
