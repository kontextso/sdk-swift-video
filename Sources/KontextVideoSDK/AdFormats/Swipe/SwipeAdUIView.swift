import AVFoundation
import UIKit

/// Full-screen video creative with an AD badge and a Skip chip that counts
/// down `skip_after_ms`. Plays with sound; tapping the video opens the
/// click-through.
final class SwipeAdUIView: UIView {
    private let ad: VideoAd
    private let style: SwipeAd.Style
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let skipChip = UIButton(type: .system)
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var reportedQuartile = 0
    private var firstFrameReported = false
    private var skippableReported = false

    var onClick: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    /// 1 = first quartile, 2 = midpoint, 3 = third quartile.
    var onProgress: ((Int) -> Void)?
    var onSkippable: (() -> Void)?
    var onSkipTapped: (() -> Void)?
    var onComplete: (() -> Void)?
    /// The media failed to load or play. The ad cannot be shown.
    var onFailure: ((String) -> Void)?

    init(ad: VideoAd, style: SwipeAd.Style) {
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

        skipChip.titleLabel?.font = style.font
        skipChip.setTitleColor(style.textColor, for: .normal)
        skipChip.backgroundColor = style.chipBackgroundColor
        skipChip.layer.cornerRadius = 16
        skipChip.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        skipChip.translatesAutoresizingMaskIntoConstraints = false
        skipChip.isHidden = !style.showsSkipButton
        skipChip.isEnabled = false
        skipChip.addTarget(self, action: #selector(didTapSkip), for: .touchUpInside)
        addSubview(skipChip)
        updateSkipChip(elapsedMs: 0)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            badge.widthAnchor.constraint(equalToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 20),
            skipChip.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            skipChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        guard let video = ad.creative.video, let url = URL(string: video.url) else { return }
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
    }

    func play() {
        player.play()
    }

    /// Stops playback and drops the observers. Always called before the
    /// view leaves the hierarchy (hide / destroy), so nothing is left for
    /// deinit to clean up.
    func stop() {
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
        let elapsedMs = Int(seconds * 1000)
        updateSkipChip(elapsedMs: elapsedMs)
        guard let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else { return }
        let fraction = seconds / duration.seconds
        let quartile = fraction >= 0.75 ? 3 : fraction >= 0.5 ? 2 : fraction >= 0.25 ? 1 : 0
        while reportedQuartile < quartile {
            reportedQuartile += 1
            onProgress?(reportedQuartile)
        }
    }

    private func updateSkipChip(elapsedMs: Int) {
        guard let skipAfter = ad.playback?.skipAfterMs else {
            skipChip.isHidden = true
            return
        }
        let remaining = skipAfter - elapsedMs
        if remaining > 0 {
            skipChip.setTitle(String(format: style.skipCountdownFormat, Int((Double(remaining) / 1000).rounded(.up))), for: .normal)
            skipChip.isEnabled = false
        } else {
            skipChip.setTitle(style.skipTitle, for: .normal)
            skipChip.isEnabled = true
            if !skippableReported {
                skippableReported = true
                onSkippable?()
            }
        }
    }

    @objc private func didTap() {
        onClick?()
    }

    @objc private func didTapSkip() {
        onSkipTapped?()
    }
}
