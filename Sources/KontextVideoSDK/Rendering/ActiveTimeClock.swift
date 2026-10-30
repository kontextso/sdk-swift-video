import UIKit

/// The time an overlay or pause ad spends on screen while its window's scene is active (the app, for a
/// window without a scene): `overlayViewDuration` reports it, and an overlay's `duration` runs on it, so
/// both freeze in the background, or while another window of the app has the screen, and resume on return.
/// It only counts and tells; the ad decides what an elapsed duration means.
@MainActor
final class ActiveTimeClock {
    /// When the duration has run out on active time; called at most once, never after `stop()`.
    private let onElapsed: () -> Void
    /// The overlay's `duration`, seconds; `nil` when nothing should end the ad on time.
    private let duration: TimeInterval?
    private let adId: String
    /// When the current active stretch began; `nil` while the app is not active.
    private var since: TimeInterval?
    /// Active time before the current stretch, seconds.
    private var accumulated: TimeInterval = 0
    private var stopped = false
    /// The duration ran out and `onElapsed` was called: it never runs again, whatever the app's activity does.
    private var expired = false
    /// Waits out the rest of the duration during an active stretch.
    private(set) var timer: Task<Void, Never>?
    /// `nonisolated(unsafe)` only so `deinit`, which is not on the main actor, may read it for the teardown.
    nonisolated(unsafe) private(set) var observers: [any NSObjectProtocol] = []

    init(duration: TimeInterval?, adId: String, onElapsed: @escaping () -> Void) {
        self.duration = duration
        self.adId = adId
        self.onElapsed = onElapsed
    }

    /// An active stretch is running: the ad is on screen and its scene active.
    var isCounting: Bool { since != nil }

    /// Seconds on screen while the app was active, the current stretch included.
    var elapsed: TimeInterval {
        accumulated + (since.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }

    /// The ad is on screen in `window`: counts from now if its scene is active, and follows that scene. The
    /// app's own activity is followed only without a scene: when the app resigns, its scenes deactivate too.
    func start(in window: UIWindow?) {
        guard !stopped, observers.isEmpty else { return }
        let scene = window?.windowScene
        let center = NotificationCenter.default
        let pauseName = scene == nil ? UIApplication.willResignActiveNotification : UIScene.willDeactivateNotification
        let resumeName = scene == nil ? UIApplication.didBecomeActiveNotification : UIScene.didActivateNotification
        observers = [
            center.addObserver(forName: pauseName, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            },
            center.addObserver(forName: resumeName, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
        ]
        if window.map(Environment.isWindowActive) ?? Environment.isApplicationActive() { resume() }
    }

    /// The ad ended: the clock freezes for good and returns the active time it counted.
    @discardableResult
    func stop() -> TimeInterval {
        if !stopped {
            stopped = true
            pause()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
        return accumulated
    }

    private func pause() {
        if let since {
            accumulated += ProcessInfo.processInfo.systemUptime - since
            self.since = nil
        }
        timer?.cancel()
        timer = nil
        if !stopped { Logger.debug("ad \(adId.prefix(8)): clock frozen at \(accumulated) s on screen") }
    }

    private func resume() {
        guard !stopped, since == nil else { return }
        since = ProcessInfo.processInfo.systemUptime
        startTimer()
    }

    private func startTimer() {
        guard timer == nil, !expired, let duration else { return }
        // Clamped to a day: a nonsense server value must not trap the `UInt64` conversion.
        let remaining = min(max(0, duration - elapsed), 86_400)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, !Task.isCancelled, !stopped, !expired else { return }
            expired = true
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
