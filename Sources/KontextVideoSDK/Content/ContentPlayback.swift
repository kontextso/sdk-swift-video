import AVFoundation
import Combine

/// The content player of one `VideoAds`: its playhead for requests and beacons, and its playing state for
/// an overlay, which lives only while the content plays, and a pause ad, which lives only while it is paused. Fed by an `AVPlayer` (observed: `rate`, so a
/// `pause()` is seen in the same turn; `currentItem`; the item's end and time jumps) or by a
/// `ContentPlayer` (its publishers, or a read every `tickInterval`, its item included, while an overlay or pause ad is on screen). Holds an
/// `AVPlayer` weakly (the app owns it) and a `ContentPlayer` strongly (often a wrapper only the SDK holds);
/// `stop()` drops every observer, subscription and timer, and the player. Every callback carries the binding
/// it came from: one queued from a player tracked before is dropped.
@MainActor
final class ContentPlayback {
    enum Change: Equatable {
        /// The playing state changed: the value the player gave with the change, when it gave one. A pause
        /// stays a pause even if the player plays again before the change is delivered.
        case playingChanged(isPlaying: Bool?)
        /// The player moved to another item (another episode, the next loop of a looper), or `track` was
        /// called again while an overlay was on screen.
        case contentChanged
        /// The item played to its end, whatever the player does next.
        case contentEnded
        /// The time jumped (a seek): an overlay's count of seconds of video starts again from here.
        case seeked
        /// `tickInterval` passed while ticking: an overlay counts its seconds of video.
        case tick
    }

    /// How often a tick comes while an overlay or pause ad is on screen. Tests shorten it.
    static var tickInterval: TimeInterval = 0.25

    /// Every change, on the main actor; the `VideoAds` passes it to its ad on screen.
    var onChange: ((Change) -> Void)?
    /// Whether an overlay or pause ad of the `VideoAds` is on screen now, an ad that follows the content;
    /// set by the `VideoAds`.
    var isFollowerShown: () -> Bool = { false }
    /// `track` was called and `stop()` was not since: a player was given, alive or not.
    private(set) var isTracking = false
    /// A binding is stopping the player it replaces: a `track` from that player's cancellation replaces it too.
    private var isReplacing = false
    /// Which binding is current; a callback from an older one is dropped.
    private var generation = 0
    /// Which item of an `AVPlayer` its item callbacks belong to; one from an item before is dropped.
    private var itemGeneration = 0
    /// The `AVPlayer`'s current item played to its end and has not restarted (a seek; a play alone is not one) or been
    /// replaced: it plays nothing, whatever its rate (`actionAtItemEnd` `.none` keeps the rate).
    private var hasItemEnded = false
    /// Content time in seconds, `nil` once the player is gone.
    private var readTime: (() -> TimeInterval?)?
    /// Whether the content plays, `nil` once the player is gone.
    private var readPlaying: (() -> Bool?)?
    /// The playback speed when the player tells it (an `AVPlayer`'s `rate`, a `ContentPlayer`'s `playbackSpeed`),
    /// for telling fast playback from a seek.
    private var readRate: (() -> Double?)?
    private weak var avPlayer: AVPlayer?
    /// The `AVPlayer`'s item at `track`, or the first it got after: this episode. Weak: an item the app let go
    /// of is not this episode playing.
    private weak var episodeItem: AVPlayerItem?
    private var hasEpisodeItem = false
    /// A custom player's item at `track`, or the first it reported after: this episode.
    private var customEpisodeItem: AnyHashable?
    /// Another `VideoAds` tracks this one's player now: this episode no longer plays in it, until `track` again.
    private(set) var hasLostPlayer = false

    /// Whether the tracked content is no longer this `VideoAds`'s episode: another `VideoAds` took its player,
    /// or the `AVPlayer` moved to another item than this episode's. An overlay or pause ad shown now would be
    /// counted for this episode over another one. A custom player is checked by its `currentItem`; one that
    /// reports none, or no player, cannot tell: `false`.
    var playsAnotherEpisode: Bool {
        if hasLostPlayer { return true }
        if let customPlayer {
            // App code: the item is read now, and the first one seen is this episode.
            guard let item = customPlayer.currentItem else { return false }
            if customEpisodeItem == nil { customEpisodeItem = item }
            return item != customEpisodeItem
        }
        guard hasEpisodeItem, let avPlayer else { return false }
        return episodeItem == nil || avPlayer.currentItem !== episodeItem
    }
    /// The tracked `ContentPlayer`, kept alive until `stop()`.
    private var customPlayer: (any ContentPlayer)?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservers: [any NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []
    private var ticker: Task<Void, Never>?

    /// Whether the content plays. `true` when nothing was tracked: nothing to follow, an overlay runs as it
    /// would. `false` once the tracked player is gone: there is no content left to play under an overlay.
    var isPlaying: Bool {
        guard isTracking else { return true }
        return readPlaying?() ?? false
    }

    /// The playback speed, when the player tells it; a value that is not finite reads as unknown.
    var rate: Double? { readRate?().flatMap { $0.isFinite ? $0 : nil } }

    /// Content time in seconds, read now, or 0. Clamped to ten years: a broken player (NaN, infinity, a huge
    /// number) must not crash the app when a request converts it to `Int`.
    var playhead: TimeInterval {
        guard let value = readTime?(), value.isFinite else { return 0 }
        return min(max(0, value), TenYears.seconds)
    }

    /// Ticks run while a player is tracked and an overlay or pause ad of this `VideoAds` is on screen, and only then.
    var isTicking = false {
        didSet {
            guard isTicking != oldValue else { return }
            ticker?.cancel()
            ticker = nil
            guard isTicking else { return }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(seconds: Self.tickInterval)
                    guard !Task.isCancelled, let self else { return }
                    tick()
                }
            }
        }
    }

    /// One tick, or `contentChanged` when a custom player reports another item than this episode's: one without a
    /// `contentChangedPublisher` (the TTSDK adapter) moves to the next episode unseen otherwise, under the overlay
    /// or pause ad still on screen. An `AVPlayer`'s item is observed. Reading the item is app code: a `track` or
    /// `destroy()` there wins, and nothing is delivered.
    private func tick() {
        let generation = self.generation
        let change: Change = customPlayer != nil && playsAnotherEpisode ? .contentChanged : .tick
        deliver(change, from: generation)
    }

    /// The start of both `track` calls: what to read, replacing whatever was tracked. Returns whether an
    /// overlay was on screen: it followed the old player, so once the new binding is complete it hears
    /// `contentChanged` (`finishBinding`) and ends. `nil` when app code run by the teardown bound or stopped
    /// the playback itself: that call won.
    private func bind(time: @escaping () -> TimeInterval?, playing: @escaping () -> Bool?, rate: @escaping () -> Double? = { nil }) -> Bool? {
        let expected = generation + 1
        // Only a player that replaces another hands the overlay over: the first `track` while an overlay runs on
        // its own time (a player made late) leaves it on screen, following the content from here.
        // A `track` from the old player's cancellation, inside `stop()`, replaces it too.
        let replacesPlayer = isTracking || isReplacing
        isReplacing = replacesPlayer
        stop()
        isReplacing = false
        // The old subscription's cancellation is app code: a `track` or `destroy()` there won, and this binding stops.
        guard generation == expected else { return nil }
        // Asked of the ad on screen, not of the ticks: a `track` nested in the cancellation runs after `stop()`
        // turned them off, and must still hand the overlay over.
        let overlayShown = isFollowerShown()
        isTracking = true
        readTime = time
        readPlaying = playing
        readRate = rate
        isTicking = overlayShown
        return overlayShown && replacesPlayer
    }

    /// The binding is complete: an overlay that followed the old player ends. Last, because its `didEnd` is
    /// app code: a `destroy()` or another `track` there wins, and this binding does nothing more.
    private func finishBinding(wasOverlayShown: Bool) {
        if wasOverlayShown { deliver(.contentChanged, from: generation) }
    }

    func track(_ player: AVPlayer) {
        // `seconds` is NaN for an invalid or indefinite time; `playhead` turns that into 0. `rate` is the rate
        // asked for: 0 after `pause()`, unchanged while buffering, and at the end only with `actionAtItemEnd`
        // `.pause`; the item's end is observed on its own and holds until the item restarts or is replaced.
        guard let wasOverlayShown = bind(time: { [weak player] in player?.currentTime().seconds },
                                         playing: { [weak self, weak player] in player.map { $0.rate != 0 && self?.hasItemEnded != true } },
                                         rate: { [weak player] in player.map { Double($0.rate) } }) else { return }
        avPlayer = player
        adoptEpisodeItem(player.currentItem)
        let generation = self.generation
        observations = [
            player.observe(\.rate, options: [.new]) { [weak self] _, change in
                let playback = self
                let isPlaying = change.newValue.map { $0 != 0 }
                // A rate alone never restarts an ended item: play() after the end plays nothing. A seek does (`jumped`).
                Self.onMain { playback?.deliver(.playingChanged(isPlaying: isPlaying), from: generation) }
            },
            player.observe(\.currentItem) { [weak self] _, _ in
                let playback = self
                Self.onMain {
                    guard let playback, playback.generation == generation else { return }
                    playback.adoptEpisodeItem(playback.avPlayer?.currentItem)
                    playback.observeItem(playback.avPlayer?.currentItem)
                    playback.deliver(.contentChanged, from: generation)
                }
            },
        ]
        observeItem(player.currentItem)
        finishBinding(wasOverlayShown: wasOverlayShown)
        // The overlay's `didEnd` there is app code: a `track` or `destroy()` in it won.
        guard generation == self.generation else { return }
        PlayerOwnership.claim(self, player: player)
    }

    func track(_ player: some ContentPlayer) {
        guard let wasOverlayShown = bind(time: { [weak player] in player?.currentTime }, playing: { [weak player] in player?.isPlaying },
                                         rate: { [weak player] in player?.playbackSpeed }) else { return }
        // The binding's own generation, taken before the item is read: `currentItem` is app code, and a `destroy()`
        // or another `track` there wins, so this binding stops instead of adopting what that code left.
        let generation = self.generation
        let item = player.currentItem
        guard generation == self.generation else { return }
        customPlayer = player
        customEpisodeItem = item
        // Reading the publishers and subscribing are app code: a `destroy()` or another `track` there wins, and
        // this binding's subscriptions are dropped instead of stored. A seek and another item are what an
        // `AVPlayer`'s time jump and item change are.
        let playing = player.isPlayingPublisher?
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                MainActor.assumeIsolated { self?.deliver(.playingChanged(isPlaying: isPlaying), from: generation) }
            }
        let seeks = player.seekPublisher?
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.deliver(.seeked, from: generation) } }
        let changes = player.contentChangedPublisher?
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.deliver(.contentChanged, from: generation) } }
        let subscriptions = [playing, seeks, changes].compactMap { $0 }
        guard generation == self.generation else {
            subscriptions.forEach { $0.cancel() }
            return
        }
        self.subscriptions = subscriptions
        finishBinding(wasOverlayShown: wasOverlayShown)
        guard generation == self.generation else { return }
        PlayerOwnership.claim(self, player: player)
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
        // Kept, not released here: releasing cancels them, and their cancellation runs the app's code.
        let subscriptions = self.subscriptions
        self.subscriptions = []
        // Released after the cancellation, for the same reason: its deinit is the app's code too.
        let customPlayer = self.customPlayer
        self.customPlayer = nil
        readTime = nil
        readPlaying = nil
        readRate = nil
        avPlayer = nil
        episodeItem = nil
        hasEpisodeItem = false
        customEpisodeItem = nil
        hasLostPlayer = false
        PlayerOwnership.release(self)
        hasItemEnded = false
        isTracking = false
        isTicking = false
        // Last, with every property settled: a `track` or `destroy()` in the cancellation finds a stopped playback.
        withExtendedLifetime(customPlayer) { subscriptions.forEach { $0.cancel() } }
    }

    /// Another `VideoAds` took the player. An overlay or pause ad on screen hears `contentChanged` first, as
    /// for another item: an overlay ends. Its `didEnd` is app code: a `track` there wins.
    func losePlayer() {
        let generation = self.generation
        if isFollowerShown() { deliver(.contentChanged, from: generation) }
        guard generation == self.generation else { return }
        Logger.info("the player is tracked by another VideoAds now; this one no longer tracks it")
        stop()
        hasLostPlayer = true
    }

    /// The first item seen from `track` on is this episode's: one there at `track`, or the first the player got.
    private func adoptEpisodeItem(_ item: AVPlayerItem?) {
        guard !hasEpisodeItem, let item else { return }
        episodeItem = item
        hasEpisodeItem = true
    }

    /// The end and the time jumps of the item the player has now; the previous item's go, and its callbacks
    /// still queued are dropped.
    private func observeItem(_ item: AVPlayerItem?) {
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        itemGeneration += 1
        hasItemEnded = false
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
                Self.onMain { playback?.deliverItem(.seeked, from: generation, item: itemGeneration) }
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
        if change == .contentEnded { hasItemEnded = true }
        if change == .seeked { hasItemEnded = false }
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
