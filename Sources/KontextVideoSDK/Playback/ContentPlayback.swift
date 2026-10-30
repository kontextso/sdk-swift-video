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
/// `pause()` is seen in the same turn; `currentItem`; the item's end and time jumps) or by a
/// `VideoAdsPlayer` (its publisher, or a read every `tickInterval` while an overlay is on screen). Holds the
/// player weakly; `stop()` drops every observer, subscription and timer. Every callback carries the binding
/// it came from: one queued from a player tracked before is dropped.
@MainActor
final class ContentPlayback {
    enum Change: Equatable {
        /// The playing state changed: the value the player gave with the change, when it gave one. A pause
        /// stays a pause even if the player plays again before the change is delivered.
        case playback(isPlaying: Bool?)
        /// The player moved to another item (another episode, the next loop of a looper), or `track` was
        /// called again while an overlay was on screen.
        case contentChanged
        /// The item played to its end, whatever the player does next.
        case contentEnded
        /// The time jumped (a seek): an overlay's count of seconds of video starts again from here.
        case jumped
        /// `tickInterval` passed while ticking: an overlay counts its seconds of video.
        case tick
    }

    /// How often a tick comes while an overlay is on screen. Tests shorten it.
    static var tickInterval: TimeInterval = 0.25

    /// Every change, on the main actor; the `VideoAds` passes it to its ad on screen.
    var onChange: ((Change) -> Void)?
    /// `track` was called and `stop()` was not since: a player was given, alive or not.
    private(set) var isTracking = false
    /// Which binding is current; a callback from an older one is dropped.
    private var generation = 0
    /// Content time in seconds, `nil` once the player is gone.
    private var readTime: (() -> TimeInterval?)?
    /// Whether the content plays, `nil` once the player is gone.
    private var readPlaying: (() -> Bool?)?
    private weak var avPlayer: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservers: [any NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var ticker: Task<Void, Never>?

    /// Whether the content plays. `true` when nothing was tracked: nothing to follow, an overlay runs as it
    /// would. `false` once the tracked player is gone: there is no content left to play under an overlay.
    var isPlaying: Bool {
        guard isTracking else { return true }
        return readPlaying?() ?? false
    }

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

    /// The core of both `track` calls: what to read. Replaces whatever was tracked; an overlay on screen
    /// followed the old player, so it hears `contentChanged` and ends.
    func track(time: @escaping () -> TimeInterval?, playing: @escaping () -> Bool?) {
        let ticking = isTicking
        stop()
        isTracking = true
        readTime = time
        readPlaying = playing
        isTicking = ticking
        if ticking { onChange?(.contentChanged) }
    }

    func track(_ player: AVPlayer) {
        // `seconds` is NaN for an invalid or indefinite time; `playhead` turns that into 0. `rate` is the rate
        // asked for: 0 after `pause()`, unchanged while buffering, and at the end only with `actionAtItemEnd`
        // `.pause`; the item's end is observed on its own.
        track(time: { [weak player] in player?.currentTime().seconds }, playing: { [weak player] in player.map { $0.rate != 0 } })
        avPlayer = player
        let generation = self.generation
        observations = [
            player.observe(\.rate, options: [.new]) { [weak self] _, change in
                let playback = self
                let playing = change.newValue.map { $0 != 0 }
                Self.onMain { playback?.deliver(.playback(isPlaying: playing), from: generation) }
            },
            player.observe(\.currentItem) { [weak self] _, _ in
                let playback = self
                Self.onMain {
                    guard let playback, playback.generation == generation else { return }
                    playback.observeItem(playback.avPlayer?.currentItem)
                    playback.deliver(.contentChanged, from: generation)
                }
            },
        ]
        observeItem(player.currentItem)
    }

    func track(_ player: some VideoAdsPlayer) {
        track(time: { [weak player] in player?.currentTime }, playing: { [weak player] in player?.isPlaying })
        let generation = self.generation
        subscription = player.isPlayingPublisher?
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                MainActor.assumeIsolated { self?.deliver(.playback(isPlaying: playing), from: generation) }
            }
    }

    /// A playhead and no playing state: an overlay runs on its own time. For the tests, which read the
    /// playhead from a closure.
    func trackPlayheadOnly(_ time: @escaping () -> TimeInterval?) { // swiftlint:disable:this unused_declaration
        stop()
        readTime = time
    }

    /// Nothing tracked any more: observers, subscription and ticks go, and the player is no longer read.
    func stop() {
        generation += 1
        observations.forEach { $0.invalidate() }
        observations = []
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        subscription = nil
        readTime = nil
        readPlaying = nil
        avPlayer = nil
        isTracking = false
        isTicking = false
    }

    /// The end and the time jumps of the item the player has now; the previous item's go.
    private func observeItem(_ item: AVPlayerItem?) {
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        guard let item else { return }
        let generation = self.generation
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { [weak self] _ in
                let playback = self
                Self.onMain { playback?.deliver(.contentEnded, from: generation) }
            },
            center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: nil) { [weak self] _ in
                let playback = self
                Self.onMain { playback?.deliver(.jumped, from: generation) }
            },
        ]
    }

    private func deliver(_ change: Change, from generation: Int) {
        guard generation == self.generation else { return }
        onChange?(change)
    }

    /// KVO and notifications call back on the thread that made the change: the app's, usually the main thread.
    private nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }
}

/// An overlay's `duration` in seconds of video: the playhead's progress while the overlay is on screen and
/// its scene active. A step backwards, or one faster than `maxRate` times the real time since the playhead
/// last moved, is a seek or a loop: it counts nothing, and counting goes on from the new position. An
/// `AVPlayer`'s time jumps also start the count again (`resync`). A custom player's seek that looks like
/// playback (small, or after a long stall) can count.
@MainActor
final class ContentProgress {
    /// Faster than any playback speed a player offers (2× at most, usually), with room for a late sample.
    static let maxRate: Double = 2.5
    /// What a step may exceed `maxRate` by: the sampling's own jitter.
    static let slack: TimeInterval = 0.25
    let duration: TimeInterval
    private(set) var elapsed: TimeInterval = 0
    private var last: TimeInterval
    private var lastMovedAt: TimeInterval

    init(duration: TimeInterval, at playhead: TimeInterval) {
        self.duration = duration
        last = playhead
        lastMovedAt = Environment.now()
    }

    /// The count goes on from `playhead`, nothing counted for the way there.
    func resync(to playhead: TimeInterval) {
        last = playhead
        lastMovedAt = Environment.now()
    }

    /// Takes the playhead now; counts the step when `counting` and it looks like playback. `true` once the
    /// duration is reached.
    func advance(to playhead: TimeInterval, counting: Bool) -> Bool {
        let step = playhead - last
        if step != 0 {
            let now = Environment.now()
            let real = now - lastMovedAt
            last = playhead
            lastMovedAt = now
            if counting, step > 0, step <= real * Self.maxRate + Self.slack { elapsed += step }
        }
        return elapsed >= duration
    }
}
