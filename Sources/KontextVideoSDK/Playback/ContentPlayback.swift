import AVFoundation
import Combine

/// Your player, as the SDK reads it: where the content is, and whether it plays. Pass it to
/// `VideoAds.track(_:)`; an `AVPlayer` needs no conformance, `track` takes it directly. The SDK holds it
/// weakly and reads it on the main actor.
@MainActor
public protocol VideoAdsPlayer: AnyObject {
    /// Where the content is, in seconds of the episode.
    var currentTime: TimeInterval { get }
    /// `false` when the viewer or your app paused the content, or it ended. Buffering and seeking count as
    /// playing: the content is about to move on.
    var isPlaying: Bool { get }
    /// Optional: emits whenever `isPlaying` changes, for an immediate reaction. Without it the SDK reads
    /// `isPlaying` four times a second while an overlay is on screen, and at every `show`.
    var isPlayingPublisher: AnyPublisher<Bool, Never>? { get }
}

extension VideoAdsPlayer {
    /// No publisher: the SDK reads `isPlaying` when it needs it.
    public var isPlayingPublisher: AnyPublisher<Bool, Never>? { nil }
}

/// The content player of one `VideoAds`: its playhead for requests and beacons, and its playing state for
/// an overlay, which lives only while the content plays. Fed by an `AVPlayer` (observed: `rate`, so a
/// `pause()` is seen in the same turn, and `currentItem`) or by a `VideoAdsPlayer` (its publisher, or a
/// read every `tickInterval` while an overlay is on screen). Holds the player weakly; `stop()` and the
/// release drop every observer, subscription and timer.
@MainActor
final class ContentPlayback {
    enum Change: Equatable {
        /// The playing state may have changed.
        case playback
        /// The player moved to another item: another episode, or the next loop of a looper.
        case contentChanged
        /// `tickInterval` passed while ticking: an overlay counts its seconds of video.
        case tick
    }

    /// How often a tick comes while an overlay is on screen. Tests shorten it.
    static var tickInterval: TimeInterval = 0.25

    /// Every change, on the main actor; the `VideoAds` passes it to its ad on screen.
    var onChange: ((Change) -> Void)?
    /// Content time in seconds, `nil` once the player is gone.
    private var readTime: (() -> TimeInterval?)?
    /// Whether the content plays, `nil` once the player is gone.
    private var readPlaying: (() -> Bool?)?
    private var observations: [NSKeyValueObservation] = []
    private var subscription: AnyCancellable?
    private var ticker: Task<Void, Never>?

    /// A player is tracked and still alive.
    var isTracking: Bool { readPlaying?() != nil }
    /// Whether the content plays; `true` without a player: nothing to follow, an overlay runs as it would.
    var isPlaying: Bool { readPlaying?() ?? true }
    /// Content time in seconds, read now, or 0. Clamped to ten years: a broken player (NaN, infinity, a huge
    /// number) must not crash the app when a request converts it to `Int`.
    var playhead: TimeInterval {
        guard let value = readTime?(), value.isFinite else { return 0 }
        return min(max(0, value), 315_360_000)
    }

    /// Ticks run while an overlay of this `VideoAds` is on screen, and only then.
    var isTicking = false {
        didSet {
            guard isTicking != oldValue else { return }
            ticker?.cancel()
            ticker = nil
            guard isTicking else { return }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    onChange?(.tick)
                }
            }
        }
    }

    /// The core of both `track` calls: what to read. Replaces whatever was tracked.
    func track(time: @escaping () -> TimeInterval?, playing: @escaping () -> Bool?) {
        stop()
        readTime = time
        readPlaying = playing
    }

    func track(_ player: AVPlayer) {
        // `seconds` is NaN for an invalid or indefinite time; `playhead` turns that into 0. `rate` is the rate
        // asked for: 0 after `pause()` or at the end, unchanged while buffering.
        track(time: { [weak player] in player?.currentTime().seconds }, playing: { [weak player] in player.map { $0.rate != 0 } })
        observations = [
            player.observe(\.rate) { [weak self] _, _ in
                let playback = self
                Self.onMain { playback?.onChange?(.playback) }
            },
            player.observe(\.currentItem) { [weak self] _, _ in
                let playback = self
                Self.onMain { playback?.onChange?(.contentChanged) }
            },
        ]
    }

    func track(_ player: some VideoAdsPlayer) {
        track(time: { [weak player] in player?.currentTime }, playing: { [weak player] in player?.isPlaying })
        subscription = player.isPlayingPublisher?
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.onChange?(.playback) } }
    }

    /// Nothing tracked any more: observers, subscription and ticks go, and the player is no longer read.
    func stop() {
        observations.forEach { $0.invalidate() }
        observations = []
        subscription = nil
        readTime = nil
        readPlaying = nil
        isTicking = false
    }

    /// KVO calls back on the thread that changed the value: the app's, usually the main thread.
    private nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }
}

/// An overlay's `duration` in seconds of video: the playhead's progress while the overlay is on screen and
/// its scene active. A step backwards or longer than `maxStep` is a seek or a loop, not playback: it counts
/// nothing, and counting goes on from the new position.
@MainActor
final class ContentProgress {
    /// Longer than any step of playback between two ticks (`tickInterval` at up to 4×, plus a late tick).
    static let maxStep: TimeInterval = 2
    let duration: TimeInterval
    private(set) var elapsed: TimeInterval = 0
    private var last: TimeInterval

    init(duration: TimeInterval, at playhead: TimeInterval) {
        self.duration = duration
        last = playhead
    }

    /// Takes the playhead now; counts the step when `counting`. `true` once the duration is reached.
    func advance(to playhead: TimeInterval, counting: Bool) -> Bool {
        let step = playhead - last
        last = playhead
        if counting, step > 0, step <= Self.maxStep { elapsed += step }
        return elapsed >= duration
    }
}
