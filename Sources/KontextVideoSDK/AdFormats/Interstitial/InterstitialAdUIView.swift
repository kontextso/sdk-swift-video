import AVFoundation
import UIKit

/// Full-screen video creative with an AD badge and a Close chip that counts
/// down `skip_after_ms`. Plays with sound unless the server says `muted`;
/// tapping the video opens the click-through.
final class InterstitialAdUIView: UIView {
    private let ad: VideoAd
    private let style: InterstitialAd.Style
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let closeChip = UIButton(type: .system)
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var stalledObserver: NSObjectProtocol?
    private var startWatchdog: Task<Void, Never>?
    private var stallWatchdog: Task<Void, Never>?
    private var failed = false
    private var endObserver: NSObjectProtocol?
    private var reportedQuartile = 0
    private var firstFrameReported = false
    private var closableReported = false
    private var ended = false

    var onClick: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    /// 1 = first quartile, 2 = midpoint, 3 = third quartile.
    var onProgress: ((Int) -> Void)?
    var onClosable: (() -> Void)?
    var onCloseTapped: (() -> Void)?
    var onComplete: (() -> Void)?
    /// The media failed to load or play. The ad cannot be shown.
    var onFailure: ((String) -> Void)?

    init(ad: VideoAd, style: InterstitialAd.Style) {
        self.ad = ad
        self.style = style
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    private func setUp() {
        backgroundColor = style.backgroundColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))

        let badge = UILabel()
        badge.text = style.badgeText
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .black
        badge.textAlignment = .center
        badge.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        closeChip.titleLabel?.font = style.font
        closeChip.setTitleColor(style.textColor, for: .normal)
        closeChip.backgroundColor = style.chipBackgroundColor
        closeChip.layer.cornerRadius = 16
        closeChip.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        closeChip.translatesAutoresizingMaskIntoConstraints = false
        closeChip.isEnabled = false
        closeChip.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        addSubview(closeChip)
        updateCloseChip(elapsed: 0)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            badge.widthAnchor.constraint(equalToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 20),
            closeChip.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            closeChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        guard let video = ad.creative.video, let url = URL(string: video.url) else {
            // Callbacks are wired by the caller right after init returns, so
            // defer the failure a tick so `onFailure` is set.
            Task { @MainActor [weak self] in self?.fail("interstitial ad has no playable video url") }
            return
        }
        let item = AVPlayerItem(url: url)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "media failed"
            Task { @MainActor in self?.onFailure?(message) }
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = ad.playback?.muted ?? false
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                guard let self, playing, !self.firstFrameReported else { return }
                self.firstFrameReported = true
                self.startWatchdog?.cancel()
                self.stallWatchdog?.cancel()
                self.stallWatchdog = nil
                self.onFirstFrame?()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in self?.tick(seconds: seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onComplete?() }
        }
        // A stall that never recovers would trap the viewer on the ad; fail
        // after a grace period, cancelling if playback resumes.
        stalledObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.armStallWatchdog() }
        }
    }

    func play() {
        player.play()
        // The video must produce its first frame within the timeout, or the
        // SDK gives up (dead CDN, endless buffering) so the app can move on.
        startWatchdog?.cancel()
        startWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Constants.interstitialStartTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.firstFrameReported else { return }
            self.fail("interstitial ad video did not start within \(Int(Constants.interstitialStartTimeout))s")
        }
    }

    private func armStallWatchdog() {
        guard !failed, stallWatchdog == nil else { return }
        stallWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Constants.interstitialStallTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.stallWatchdog = nil
            if self.player.timeControlStatus != .playing {
                self.fail("interstitial ad video stalled for \(Int(Constants.interstitialStallTimeout))s")
            }
        }
    }

    /// Single failure funnel: reports once, then behaves like the media-
    /// failed KVO path (hide + `.error` + onDismissed in `InterstitialAd`).
    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        onFailure?(message)
    }

    /// Stops playback and drops the observers. Always called before the
    /// view leaves the hierarchy (hide / destroy), so nothing is left for
    /// deinit to clean up.
    func stop() {
        startWatchdog?.cancel(); startWatchdog = nil
        stallWatchdog?.cancel(); stallWatchdog = nil
        if let stalledObserver {
            NotificationCenter.default.removeObserver(stalledObserver)
            self.stalledObserver = nil
        }
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.replaceCurrentItem(with: nil)
    }

    private func tick(seconds: Double) {
        guard seconds.isFinite else { return }
        updateCloseChip(elapsed: seconds)
        guard let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else { return }
        let fraction = seconds / duration.seconds
        let quartile = fraction >= 0.75 ? 3 : fraction >= 0.5 ? 2 : fraction >= 0.25 ? 1 : 0
        while reportedQuartile < quartile {
            reportedQuartile += 1
            onProgress?(reportedQuartile)
        }
    }

    /// The video ended: keep the last frame (the player pauses on it) and
    /// let the viewer close whenever they like.
    func showEndState() {
        ended = true
        closeChip.setTitle(style.closeTitle, for: .normal)
        closeChip.isEnabled = true
        closeChip.isHidden = false
    }

    /// No `skip_after_ms` = closable only once the video ends, so the chip
    /// stays hidden until then.
    private func updateCloseChip(elapsed: TimeInterval) {
        guard !ended else { return }
        guard let skipAfterMs = ad.playback?.skipAfterMs else {
            closeChip.isHidden = true
            return
        }
        let remaining = TimeInterval(skipAfterMs) / 1000 - elapsed
        if remaining > 0 {
            closeChip.setTitle(String(format: style.closeCountdownFormat, Int(remaining.rounded(.up))), for: .normal)
            closeChip.isEnabled = false
        } else {
            closeChip.setTitle(style.closeTitle, for: .normal)
            closeChip.isEnabled = true
            if !closableReported {
                closableReported = true
                onClosable?()
            }
        }
    }

    @objc private func didTap() {
        onClick?()
    }

    @objc private func didTapClose() {
        onCloseTapped?()
    }
}
