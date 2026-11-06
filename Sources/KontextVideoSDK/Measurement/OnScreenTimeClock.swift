import UIKit

/// A stopwatch that runs only while the viewer can see an overlay or pause ad.
///
/// Why: an overlay's `duration` (say 10 s) must mean 10 s in front of the viewer. Without it, an app sent to
/// the background for a minute would come back to an overlay already gone, unseen; and `overlayViewDuration`
/// would report time nobody watched.
///
/// How: it runs while both are true, and pauses, keeping its time, as soon as one is not:
/// - the window's scene is active: the app is in front and so is this window (on iPad another window of the
///   app may have the screen; a window without a scene follows the app);
/// - the ad is seen: some of it is on screen, not scrolled away (the viewability meter says, `setSeen`).
/// It adds up the stretches: `accumulated` holds the finished ones, `since` when the current one began.
///
/// ```
/// shown ─ 4 s ─ background ─ (paused) ─ back ─ 6 s ─ 10 s reached: onElapsed, the ad ends
/// ```
///
/// Used for: an overlay's duration (a timer waits out only the time still missing, then calls `onElapsed`
/// once), and the active time `stop()` returns at the end, reported as `overlayViewDuration`. An overlay that
/// follows a tracked player counts its duration in video time instead (`ContentTimeClock`): its clock gets no
/// duration.
///
/// Not the 50 %-for-1-second viewability rule: that is `ViewabilityMeter`'s (at least half on screen, without
/// a break). This clock counts any part seen, with breaks. It only counts and tells; the ad decides what an
/// elapsed duration means.
@MainActor
final class OnScreenTimeClock {
    /// When the duration has run out on active time; called at most once, never after `stop()`.
    private let onElapsed: () -> Void
    /// The overlay's `duration`, seconds; `nil` when nothing should end the ad on time.
    private let duration: TimeInterval?
    private let adId: String
    /// When the current active stretch began; `nil` while the app is not active.
    private var since: TimeInterval?
    /// Active time before the current stretch, seconds.
    private var accumulated: TimeInterval = 0
    private var isStopped = false
    /// The longest the timer waits at once: a day. A nonsense server duration must not trap the `UInt64`
    /// conversion of its nanoseconds; a longer one waits again for the rest. Tests shorten it.
    static var longestWait: TimeInterval = 86_400
    /// The duration ran out and `onElapsed` was called: it never runs again, whatever the scene or the meter do.
    private var hasElapsed = false
    /// Waits out the rest of the duration during an active stretch.
    private(set) var timer: Task<Void, Never>?
    /// `nonisolated(unsafe)` only so `deinit`, which is not on the main actor, may read it for the teardown.
    nonisolated(unsafe) private(set) var observers: [any NSObjectProtocol] = []

    init(duration: TimeInterval?, adId: String, onElapsed: @escaping () -> Void) {
        self.duration = duration
        self.adId = adId
        self.onElapsed = onElapsed
    }

    /// An active stretch is running: the ad is seen and its scene active.
    var isCounting: Bool { since != nil }
    /// The ad's scene is active, whether or not the ad is seen.
    private(set) var isSceneActive = false
    /// The meter's last answer: some of the ad on screen. Seen until it says otherwise.
    private var isSeen = true

    /// The meter's answer changed: the clock counts only while the ad is seen.
    func setSeen(_ isSeen: Bool) {
        self.isSeen = isSeen
        update()
    }
    /// Called whenever counting resumes after the clock started: the scene came back, or the ad came back into
    /// sight (the meter's seen flip). An overlay that counts seconds of video starts its count again from there,
    /// so time unseen counts nothing.
    var onResume: (() -> Void)?

    /// Seconds on screen while the app was active, the current stretch included.
    var elapsed: TimeInterval {
        accumulated + (since.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }

    /// The ad is on screen in `window`: counts from now if its scene is active, and follows that scene. The
    /// app's own activity is followed only without a scene: when the app resigns, its scenes deactivate too.
    func start(in window: UIWindow?) {
        guard !isStopped, observers.isEmpty else { return }
        let scene = window?.windowScene
        let center = NotificationCenter.default
        let pauseName = scene == nil ? UIApplication.willResignActiveNotification : UIScene.willDeactivateNotification
        let resumeName = scene == nil ? UIApplication.didBecomeActiveNotification : UIScene.didActivateNotification
        observers = [
            center.addObserver(forName: pauseName, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSceneActive(false) }
            },
            center.addObserver(forName: resumeName, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSceneActive(true) }
            },
        ]
        setSceneActive(window.map(Environment.isWindowActive) ?? Environment.isApplicationActive())
    }

    /// The ad ended: the clock freezes for good and returns the active time it counted.
    @discardableResult
    func stop() -> TimeInterval {
        if !isStopped {
            isStopped = true
            pause()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
        return accumulated
    }

    // MARK: Private

    private func setSceneActive(_ isActive: Bool) {
        isSceneActive = isActive
        update()
    }

    private func update() {
        if isSceneActive, isSeen { resume() } else { pause() }
    }

    private func pause() {
        timer?.cancel()
        timer = nil
        guard let since else { return }
        accumulated += ProcessInfo.processInfo.systemUptime - since
        self.since = nil
        if !isStopped { Logger.debug("ad \(adId.prefix(8)): clock frozen at \(accumulated) s on screen") }
    }

    private func resume() {
        guard !isStopped, since == nil else { return }
        since = ProcessInfo.processInfo.systemUptime
        startTimer()
        onResume?()
    }

    private func startTimer() {
        guard timer == nil, !hasElapsed, let duration else { return }
        let left = max(0, duration - elapsed)
        let remaining = min(left, Self.longestWait)
        timer = Task { [weak self] in
            try? await Task.sleep(seconds: remaining)
            guard let self, !Task.isCancelled, !isStopped, !hasElapsed else { return }
            // A capped wait is one stretch of a longer duration, not its end: wait again for the rest.
            if remaining < left {
                timer = nil
                return startTimer()
            }
            hasElapsed = true
            onElapsed()
        }
    }

    deinit {
        let timer = self.timer
        let observers = self.observers
        let teardown: @MainActor () -> Void = {
            timer?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            Task { @MainActor in teardown() }
        }
    }
}
