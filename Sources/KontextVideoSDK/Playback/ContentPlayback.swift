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
    /// Whether an overlay of the `VideoAds` is on screen now; set by the `VideoAds`.
    var isOverlayShown: () -> Bool = { false }
    /// `track` was called and `stop()` was not since: a player was given, alive or not.
    private(set) var isTracking = false
    /// Which binding is current; a callback from an older one is dropped.
    private var generation = 0
    /// Which item of an `AVPlayer` its item callbacks belong to; one from an item before is dropped.
    private var itemGeneration = 0
    /// The `AVPlayer`'s current item played to its end and has not restarted (a seek; a play alone is not one) or been
    /// replaced: it plays nothing, whatever its rate (`actionAtItemEnd` `.none` keeps the rate).
    private var itemEnded = false
    /// Content time in seconds, `nil` once the player is gone.
    private var readTime: (() -> TimeInterval?)?
    /// Whether the content plays, `nil` once the player is gone.
    private var readPlaying: (() -> Bool?)?
    /// The playback speed when the player tells it (an `AVPlayer`'s `rate`), for telling fast playback from a seek.
    private var readRate: (() -> Double?)?
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

    /// The playback speed, when the player tells it.
    var rate: Double? { readRate?() }

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

    /// The start of both `track` calls: what to read, replacing whatever was tracked. Returns whether an
    /// overlay was on screen: it followed the old player, so once the new binding is complete it hears
    /// `contentChanged` (`finishBinding`) and ends. `nil` when app code run by the teardown bound or stopped
    /// the playback itself: that call won.
    private func bind(time: @escaping () -> TimeInterval?, playing: @escaping () -> Bool?, rate: @escaping () -> Double? = { nil }) -> Bool? {
        let expected = generation + 1
        stop()
        // The old subscription's cancellation is app code: a `track` or `destroy()` there won, and this binding stops.
        guard generation == expected else { return nil }
        // Asked of the ad on screen, not of the ticks: a `track` nested in the cancellation runs after `stop()`
        // turned them off, and must still hand the overlay over.
        let overlayShown = isOverlayShown()
        isTracking = true
        readTime = time
        readPlaying = playing
        readRate = rate
        isTicking = overlayShown
        return overlayShown
    }

    /// The binding is complete: an overlay that followed the old player ends. Last, because its `didEnd` is
    /// app code: a `destroy()` or another `track` there wins, and this binding does nothing more.
    private func finishBinding(overlayWasShown: Bool) {
        if overlayWasShown { deliver(.contentChanged, from: generation) }
    }

    func track(_ player: AVPlayer) {
        // `seconds` is NaN for an invalid or indefinite time; `playhead` turns that into 0. `rate` is the rate
        // asked for: 0 after `pause()`, unchanged while buffering, and at the end only with `actionAtItemEnd`
        // `.pause`; the item's end is observed on its own and holds until the item restarts or is replaced.
        guard let overlayWasShown = bind(time: { [weak player] in player?.currentTime().seconds },
                                         playing: { [weak self, weak player] in player.map { $0.rate != 0 && self?.itemEnded != true } },
                                         rate: { [weak player] in player.map { Double($0.rate) } }) else { return }
        avPlayer = player
        let generation = self.generation
        observations = [
            player.observe(\.rate, options: [.new]) { [weak self] _, change in
                let playback = self
                let playing = change.newValue.map { $0 != 0 }
                // A rate alone never restarts an ended item: play() after the end plays nothing. A seek does (`jumped`).
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
        finishBinding(overlayWasShown: overlayWasShown)
    }

    func track(_ player: some VideoAdsPlayer) {
        guard let overlayWasShown = bind(time: { [weak player] in player?.currentTime }, playing: { [weak player] in player?.isPlaying }) else { return }
        let generation = self.generation
        // Reading the publisher and subscribing are app code: a `destroy()` or another `track` there wins, and
        // this binding's subscription is dropped instead of stored.
        let subscription = player.isPlayingPublisher?
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                MainActor.assumeIsolated { self?.deliver(.playback(isPlaying: playing), from: generation) }
            }
        guard generation == self.generation else {
            subscription?.cancel()
            return
        }
        self.subscription = subscription
        finishBinding(overlayWasShown: overlayWasShown)
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
        // Kept, not released here: releasing cancels it, and its cancellation runs the app's code.
        let subscription = self.subscription
        self.subscription = nil
        readTime = nil
        readPlaying = nil
        readRate = nil
        avPlayer = nil
        itemEnded = false
        isTracking = false
        isTicking = false
        // Last, with every property settled: a `track` or `destroy()` in the cancellation finds a stopped playback.
        subscription?.cancel()
    }

    /// The end and the time jumps of the item the player has now; the previous item's go, and its callbacks
    /// still queued are dropped.
    private func observeItem(_ item: AVPlayerItem?) {
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        itemGeneration += 1
        itemEnded = false
        guard let item else { return }
        let generation = self.generation
        let itemGeneration = self.itemGeneration
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { [weak self] _ in
                let playback = self
                Self.onMain { playback?.deliverItem(.contentEnded, from: generation, item: itemGeneration) }
            },
            center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: nil) { [weak self] _ in
                let playback = self
                Self.onMain { playback?.deliverItem(.jumped, from: generation, item: itemGeneration) }
            },
        ]
    }

    private func deliver(_ change: Change, from generation: Int) {
        guard generation == self.generation else { return }
        onChange?(change)
    }

    /// An item's callback: dropped when the player moved to another item since. The end holds until the item
    /// restarts (a time jump, a seek back to play it again).
    private func deliverItem(_ change: Change, from generation: Int, item: Int) {
        guard generation == self.generation, item == itemGeneration else { return }
        if change == .contentEnded { itemEnded = true }
        if change == .jumped { itemEnded = false }
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
/// its scene active (`resync` when the scene comes back, so time hidden counts nothing). A step backwards,
/// or one faster than the playback speed allows for the real time since the playhead last moved, is a seek
/// or a loop: it counts nothing, and counting goes on from the new position. An `AVPlayer` gives its speed,
/// and its time jumps start the count again; for a custom player the limit is `maxRate`, so a seek that
/// looks like playback (small, or after a long stall) can count.
@MainActor
final class ContentProgress {
    /// The speed allowed when the player does not tell its own: 4× playback and a late sample still count.
    static let maxRate: Double = 4.25
    /// Room above a known speed for a late sample.
    static let rateMargin: Double = 1.25
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

    /// Takes the playhead now; counts the step when `counting` and it looks like playback at `rate` (the
    /// player's speed, `nil` when unknown). `true` once the duration is reached.
    func advance(to playhead: TimeInterval, counting: Bool, rate: Double? = nil) -> Bool {
        let step = playhead - last
        if step != 0 {
            let now = Environment.now()
            let real = now - lastMovedAt
            last = playhead
            lastMovedAt = now
            let speed = rate.map { max(abs($0) * Self.rateMargin, 1) } ?? Self.maxRate
            if counting, step > 0, step <= real * speed + Self.slack { elapsed += step }
        }
        return elapsed >= duration
    }
}
