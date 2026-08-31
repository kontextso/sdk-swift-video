import UIKit

/// The `swipe` placement of one video: a full-screen video interstitial
/// shown once when the user swipes forward to the next episode (Google's
/// `SwipeableInterstitialAd` model: the app hosts the view, holds the swipe
/// for the server's `skip_after_ms`, then a swipe dismisses it for good —
/// swiping back never brings it back). The SDK plays the video with its
/// own player; the app owns the swipe gesture:
///
/// ```swift
/// // the user swiped forward to the next episode
/// if ads.swipe.isReady {
///     ads.swipe.show(in: adHostView,
///         onSkippable: { allowSwipe = true },      // server's skip_after_ms elapsed
///         onFinished: { goToNextEpisode() })       // played to the end, already hidden
/// }
/// // the user swiped the ad away (only allow it after onSkippable)
/// ads.swipe.hide()                                // fires `skip`, emits .closed
/// ```
@MainActor
public final class SwipeAd: AdPlacement {
    /// Appearance of the swipe ad. Everything has a default.
    public struct Style: Sendable {
        public var backgroundColor: UIColor = .black
        /// Label shown while the ad cannot be skipped yet, with the
        /// remaining seconds: e.g. "Skip in 5".
        public var skipCountdownFormat: String = "Skip in %d"
        /// Label once skipping is allowed.
        public var skipTitle: String = "Skip"
        public var badgeText: String = "AD"
        public var font: UIFont = .systemFont(ofSize: 13, weight: .semibold)
        public var textColor: UIColor = .white
        public var chipBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.45)
        /// Hides the built-in Skip button when the app draws its own or
        /// relies on the swipe alone.
        public var showsSkipButton: Bool = true

        public init() {}
    }

    /// `true` once the server's `skip_after_ms` has elapsed (or at once when
    /// the ad is not skippable-gated). The app may let the user swipe.
    public private(set) var isSkippable = false

    private var style = Style()
    private var onSkippable: (() -> Void)?
    private var onFinished: (() -> Void)?
    private var completed = false

    init(videoId: String, emit: @escaping (VideoAdEvent) -> Void) {
        super.init(format: .swipe, videoId: videoId, emit: emit)
    }

    /// Shows the next ad in `container` (a full-screen page the app inserted
    /// into its feed) and starts playback with sound. Returns `false` when
    /// ``isReady`` is `false`.
    ///
    /// - Parameters:
    ///   - onSkippable: The ad may now be swiped away (`skip_after_ms`
    ///     elapsed). Unblock the swipe gesture here.
    ///   - onFinished: The ad is over — played to the end or skipped with
    ///     its Skip button — and already hidden. Move on to the next
    ///     episode here. (Not called for your own `hide()`.)
    @discardableResult
    public func show(
        in container: UIView,
        style: Style = Style(),
        onSkippable: @escaping () -> Void,
        onFinished: @escaping () -> Void
    ) -> Bool {
        self.style = style
        self.onSkippable = onSkippable
        self.onFinished = onFinished
        isSkippable = false
        completed = false
        return present(in: container)
    }

    override func makeView(for ad: VideoAd) -> UIView {
        let view = SwipeAdUIView(ad: ad, style: style)
        view.onClick = { [weak self] in self?.onClick() }
        view.onFirstFrame = { [weak self] in
            self?.onCreativeRendered()
            self?.tracker?.fireVideo(.start)
        }
        view.onProgress = { [weak self] quartile in
            switch quartile {
            case 1: self?.tracker?.fireVideo(.firstQuartile)
            case 2: self?.tracker?.fireVideo(.midpoint)
            case 3: self?.tracker?.fireVideo(.thirdQuartile)
            default: break
            }
        }
        view.onSkippable = { [weak self] in
            guard let self, !self.isSkippable else { return }
            self.isSkippable = true
            self.onSkippable?()
        }
        view.onSkipTapped = { [weak self] in
            // Skip is the ad's own control, so the app needs `onFinished`
            // just like on completion — otherwise it is left holding an
            // empty host view.
            self?.onUserDismiss()
            self?.onFinished?()
        }
        view.onFailure = { [weak self] message in
            // Unplayable media: tear down without tracking and let the app
            // move on, exactly as if the ad had finished.
            guard let self, let ad = self.current else { return }
            self.completed = true
            self.hide(userDismissed: false)
            self.emit(.error(VideoAdEvent.ErrorData(videoId: self.videoId, message: "swipe ad \(ad.bidId): \(message)")))
            self.onFinished?()
        }
        view.onComplete = { [weak self] in
            guard let self, let ad = self.current, !self.completed else { return }
            self.completed = true
            self.tracker?.fireVideo(.complete)
            self.hide(userDismissed: false)
            self.emit(.completed(VideoAdEvent.AdData(format: .swipe, videoId: self.videoId, bidId: ad.bidId)))
            self.onFinished?()
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
        (view as? SwipeAdUIView)?.play()
    }

    /// Hides the ad. Called by the app when the user swiped it away: fires
    /// `skip` and emits `.closed`. A hide after completion is a no-op.
    public override func hide() {
        guard let ad = current, !completed else {
            super.hide(userDismissed: false)
            return
        }
        super.hide(userDismissed: true)
        emit(.closed(VideoAdEvent.AdData(format: .swipe, videoId: videoId, bidId: ad.bidId)))
    }

    override func willHide(userDismissed: Bool) {
        (view as? SwipeAdUIView)?.stop()
        if userDismissed, !completed {
            tracker?.fireVideo(.skip)
        }
    }
}
