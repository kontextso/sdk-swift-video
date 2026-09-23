import UIKit

/// The `interstitial` placement of one video: a full-screen video ad the
/// SDK presents itself, at a moment the app chooses (the model of MAX's
/// `MAInterstitialAd`, AdMob's `GADInterstitialAd` and LevelPlay's
/// `LPMInterstitialAd`: `isReady` → `show(from:)` → dismissed callback).
/// The SDK owns the screen, the AD badge and the Close chip; the app only
/// pauses its content before `show` and resumes it in `onDismissed`:
///
/// ```swift
/// if ads.interstitial.isReady {
///     player.pause()
///     ads.interstitial.show(from: viewController) { player.play() }
/// }
/// ```
///
/// Close is server-driven: the chip counts down `playback.skip_after_ms`
/// and enables after it; with no `skip_after_ms` the ad closes only when
/// the video ends. Completion dismisses the screen on its own.
@MainActor
public final class InterstitialAd: AdPlacement {
    /// Appearance of the interstitial. Everything has a default.
    public struct Style: Sendable {
        public var backgroundColor: UIColor = .black
        /// Label shown while the ad cannot be closed yet, with the
        /// remaining seconds: e.g. "Close in 5".
        public var closeCountdownFormat: String = "Close in %d"
        /// Label once closing is allowed.
        public var closeTitle: String = "Close"
        public var badgeText: String = "AD"
        public var font: UIFont = .systemFont(ofSize: 13, weight: .semibold)
        public var textColor: UIColor = .white
        public var chipBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.45)

        public init() {}
    }

    /// `true` once the server's `skip_after_ms` has elapsed and the Close
    /// chip is enabled.
    public private(set) var isClosable = false

    private var style = Style()
    private var onDismissed: (() -> Void)?
    private var screen: InterstitialAdViewController?
    private var completed = false
    private var ended = false

    init(videoId: String, emit: @escaping (VideoAdEvent) -> Void) {
        super.init(format: .interstitial, videoId: videoId, emit: emit)
    }

    /// Presents the SDK's own full-screen controller over `viewController`,
    /// starts the video with sound (unless the server says `muted`), and
    /// consumes the ad. Returns `false` when ``isReady`` is `false`.
    ///
    /// Pause your content before calling this and resume it in
    /// `onDismissed`, which runs exactly once however the ad ended: video
    /// finished, user tapped Close, media failed, or your own ``hide()``.
    /// It does not run for ``VideoAds/destroy()``, which you initiated.
    @discardableResult
    public func show(
        from viewController: UIViewController,
        style: Style = Style(),
        onDismissed: @escaping () -> Void
    ) -> Bool {
        guard isReady else { return false }
        self.style = style
        self.onDismissed = onDismissed
        isClosable = false
        completed = false
        ended = false
        let screen = InterstitialAdViewController(backgroundColor: style.backgroundColor)
        self.screen = screen
        viewController.present(screen, animated: true)
        return present(in: screen.view)
    }

    /// Dismisses the ad because the app is leaving (viewer left the screen,
    /// app going to background). Fires `skip` when the video had not
    /// finished. Runs `onDismissed`. A hide after completion is a no-op.
    public override func hide() {
        guard current != nil else {
            super.hide()
            return
        }
        end(.hidden)
    }

    override func makeView(for ad: VideoAd) -> UIView {
        let view = InterstitialAdUIView(ad: ad, style: style)
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
        view.onClosable = { [weak self] in self?.isClosable = true }
        view.onCloseTapped = { [weak self] in self?.end(.closed) }
        view.onFailure = { [weak self] message in self?.end(.failed(message)) }
        view.onComplete = { [weak self] in self?.end(.completed) }
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
        (view as? InterstitialAdUIView)?.play()
    }

    override func willHide(userDismissed: Bool) {
        (view as? InterstitialAdUIView)?.stop()
        if userDismissed, !completed {
            tracker?.fireVideo(.skip)
        }
    }

    override func destroy() async {
        let wasOnScreen = view != nil
        await super.destroy()
        if wasOnScreen {
            dismissScreen()
        }
        onDismissed = nil
    }

    private enum End {
        case completed
        case closed
        case failed(String)
        case hidden
    }

    /// Single exit: every way the ad can end goes through here, so the
    /// screen is dismissed and `onDismissed` runs exactly once.
    private func end(_ end: End) {
        guard let ad = current, !ended else { return }
        ended = true
        switch end {
        case .completed:
            completed = true
            tracker?.fireVideo(.complete)
            hide(userDismissed: false)
            emit(.completed(VideoAdEvent.AdData(format: .interstitial, videoId: videoId, adId: ad.adId)))
        case .closed:
            onUserDismiss()
        case .failed(let message):
            // Unplayable media: tear down without skip tracking and let the
            // app move on, exactly as if the ad had finished.
            completed = true
            hide(userDismissed: false)
            emit(.error(VideoAdEvent.ErrorData(videoId: videoId, message: "interstitial ad \(ad.adId): \(message)")))
        case .hidden:
            hide(userDismissed: true)
        }
        dismissScreen()
        let callback = onDismissed
        onDismissed = nil
        callback?()
    }

    private func dismissScreen() {
        guard let screen else { return }
        self.screen = nil
        screen.presentingViewController?.dismiss(animated: true)
    }
}
