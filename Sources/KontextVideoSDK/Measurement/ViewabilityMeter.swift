import UIKit

/// A measuring loop: every 250 ms (`interval`) it asks how much of the ad's view the viewer can see right now,
/// and turns the answer into a few signals. It decides the one viewability event, the industry's (MRC) rule:
/// `viewable` once at least 50 % of the ad was on screen without a break for 1 s (2 s for a video),
/// `notViewable` when the ad ended before that, `viewUndetermined` when it could not measure.
///
/// ```
/// every 250 ms: tick()
///   ├─ screen:    onTick, the ad's screen's own check (a controller presented over an inline ad's)
///   ├─ measure:   ViewExposure.exposure(of:in:): share on screen (0–1) and the visible rectangle
///   ├─ report:    changed? onExposure(Exposure)          → the page, which tells the creative
///   │             any of it seen? changed: onSeen(bool)  → OnScreenTimeClock
///   ├─ off-screen: nothing seen for 1 s while its scene is active: onOffScreen  → the ad ends
///   └─ dwell:     ≥ 50 % without a break for the required time: onVerdict(.viewable), once
/// stop() at the ad's end: no verdict yet? .notViewable (.viewUndetermined when the view is gone)
/// ```
///
/// Outputs: `onVerdict` (the beacon), `onExposure` (`ad.exposure` to the page), `onSeen` (the clock),
/// `onOffScreen` and `onDetached` (the ad ends). Inputs: `isCovered` (something it cannot measure covers the
/// ad, such as a sheet over a linear ad) and `countsTime` (off while a video creative is not playing: a paused
/// video does not count towards its 2 s).
///
/// The two hard parts. The geometry is `ViewExposure`'s (and `Polygon`'s): how much of the view is on screen.
/// The timing is here: the 50 % stretch starts again when the share drops, the video pauses, or the loop stalled
/// (a frozen app cannot prove the time was continuous).
///
/// Not `OnScreenTimeClock`: that one adds up any time seen, with breaks; this one judges the 50 % rule.
@MainActor
final class ViewabilityMeter {
    enum Verdict: String {
        case viewable
        case notViewable
        case viewUndetermined
    }

    /// How often the box is measured. A constant in spirit: only tests set it, shorter to run fast. (Swift has no
    /// test-only marker as Android's `@VisibleForTesting`; nothing in the SDK writes it.)
    static var interval: TimeInterval = 0.25
    /// A gap between ticks shorter than this is a scheduling hiccup, not a stall: two intervals in production
    /// (0.25 s each), and still half a second when a test shrinks the interval to a few milliseconds.
    static let shortestStall: TimeInterval = 0.5
    /// The MRC rule's share: at least half the box on screen, for `requiredSeconds` without a break.
    static let threshold: Double = 0.5

    /// Exposure changed: the share on screen (rounded to the percent) and the visible rectangle in the view's
    /// coordinates (`.zero` when nothing is seen).
    var onExposure: ((Exposure) -> Void)?
    /// The verdict, once.
    var onVerdict: ((Verdict) -> Void)?
    /// Runs first on every tick: a check of the ad's screen that has no event of its own (a controller the app
    /// presented over the one holding an overlay or pause ad). It may end the ad; the tick then stops there.
    var onTick: (() -> Void)?
    /// The view left the window and did not come back within one interval: the app removed what the ad
    /// sits in, or covered it (UIKit takes a full-screen-covered controller's view out of the window).
    /// On every tick while it stays out, from the second: an owner that waits out a cover hears again once
    /// the cover is gone and the view did not come back.
    var onDetached: (() -> Void)?
    /// Whether something the meter cannot see covers the view while it stays in its window: a sheet presented
    /// over a linear ad (the App Store product page after a click), the in-app browser of the ad's click. Asked
    /// on every tick; covered reads as 0, and is not out of sight.
    var isCovered: (() -> Bool)?
    /// The ad became seen (some of it on screen in an active scene) or unseen: the one answer to "is it
    /// seen" the clock and the slot follow. From the first real measurement on, at every change.
    var onSeen: ((Bool) -> Void)?
    /// The view stayed in its window, its scene active and nothing covering it (`isCovered`), with nothing of it
    /// on screen for `offScreenGrace`: a feed cell swiped away, a view scrolled or moved out of sight. On every
    /// tick while that lasts.
    var onOffScreen: (() -> Void)?
    /// How long a view in an active scene may show nothing before `onOffScreen`. A constant in spirit: only
    /// tests set it, shorter to run fast.
    static var offScreenGrace: TimeInterval = 1
    /// The last answer `onSeen` gave; `nil` before the first real measurement.
    private(set) var isSeen: Bool?
    /// Since when the view, in an active scene, has shown nothing.
    private var offScreenSince: TimeInterval?

    private(set) var verdict: Verdict?
    private weak var view: UIView?
    private let requiredSeconds: TimeInterval
    private var timer: Timer?
    private var exposedSince: TimeInterval?
    /// When the last tick ran: a tick that comes much later than the next one was due means nothing was
    /// measured meanwhile (a stalled main thread, a suspended app), and continuity cannot be claimed.
    private var lastTick: TimeInterval?
    private var lastPercentage = -1.0
    private var lastVisible = CGRect.null
    /// Ticks in a row that found no window; from the second one on, each reports the detachment.
    private var detachedTicks = 0
    /// `stop()` was called: measuring never resumes, whatever `start()` says afterwards.
    private var isStopped = false
    /// The view has been seen laid out in a window, with a size: the first real measurement. Before it, a
    /// tick reads 0 only because the view is not placed yet (a linear ad's controller mid-layout, a container
    /// still at zero size), and a page pauses its video on 0: the page hears nothing until then, and every
    /// change afterwards, a real 0 included.
    private var hasMeasured = false
    /// Whether exposure counts towards the dwell right now. The owner turns it off while a video creative
    /// is not playing (before its start, while paused): the rule wants continuous seconds of the video
    /// played, so turning it off restarts the dwell at once, even between two ticks. Exposure is still
    /// measured and reported either way.
    var countsTime = true {
        didSet { if !countsTime { exposedSince = nil } }
    }

    init(view: UIView, requiredSeconds: TimeInterval) {
        self.view = view
        self.requiredSeconds = requiredSeconds
    }

    func start() {
        guard timer == nil, !isStopped else { return }
        // The timer first: a callback from the first tick that stops the meter must find it there. In the
        // common modes, so it keeps ticking while the viewer scrolls (the default mode pauses then).
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            // A meter released without stop() takes its timer with it, instead of leaving it in the run loop.
            guard self != nil else { return timer.invalidate() }
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// The ad ended: a verdict is still owed when none was reached. `notViewable` claims a measurement: a view gone,
    /// or one never measured (never in a window with a size, a linear ad ended before its layout), is undetermined.
    func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
        if verdict == nil {
            decide(view == nil || !hasMeasured ? .viewUndetermined : .notViewable)
        }
    }

    /// One measurement. Internal so tests can drive it with a frozen clock; the timer calls it otherwise.
    func tick() {
        // 0. The screen's own check, which may end the ad.
        onTick?()
        guard !isStopped else { return }
        // 1. Did the loop stall (more than two ticks, and at least half a second, since the last: the app froze or
        //    slept)? Then the 50 % stretch cannot be called continuous, and it starts again below.
        let now = Environment.now()
        let stalled = lastTick.map { now - $0 > max(Self.interval * 2, Self.shortestStall) } ?? false
        lastTick = now
        // 2. Is the view still there, in a window? Held weakly: the meter never keeps a view alive.
        guard let view, let window = view.window else {
            if hasMeasured { report(Exposure(share: 0, visibleBox: .zero)) }
            exposedSince = nil
            offScreenSince = nil
            // One tick of grace: a view re-parented within the same turn of the run loop is not gone. Two in a
            // row: the ad ends.
            detachedTicks += 1
            if view != nil, detachedTicks >= 2 {
                onDetached?()
            }
            return
        }
        detachedTicks = 0
        guard hasMeasured || (view.bounds.width > 0 && view.bounds.height > 0) else { return }
        hasMeasured = true
        // 3. Measure: the share on screen and its rectangle; 0 while the ad's own scene is not active (not the
        //    app: an iPad window in the background shows nothing) or something covers it.
        let active = Environment.isWindowActive(window)
        let covered = isCovered?() == true
        let seen = active && !covered
        let measured = seen ? ViewExposure.exposure(of: view, in: window) : .none
        let percentage = measured.share
        // 4. Tell: onExposure when it changed, onSeen when "any of it visible" flipped. First, so the page and
        //    the clock are current before the rules below may end the ad.
        report(Exposure(share: percentage, visibleBox: measured.visibleBox.isNull ? .zero : measured.visibleBox))
        // The page's reaction to the exposure may have ended the ad.
        guard !isStopped else { return }
        // 5. Nothing seen for a second while its scene is active and nothing covers it: onOffScreen, the ad ends.
        if active, !covered, percentage == 0 {
            if offScreenSince == nil || stalled { offScreenSince = now }
            if let since = offScreenSince, now - since >= Self.offScreenGrace {
                onOffScreen?()
                guard !isStopped else { return }
            }
        } else {
            offScreenSince = nil
        }

        // 6. The 50 % rule: the continuous time at 50 % or more; long enough, the verdict .viewable, once.
        if percentage >= Self.threshold, countsTime {
            // A gap between ticks breaks the continuity the rule asks for: the clock starts again.
            if exposedSince == nil || stalled { exposedSince = now }
            if let since = exposedSince, now - since >= requiredSeconds {
                decide(.viewable)
            }
        } else {
            exposedSince = nil
        }
    }

    /// The page hears about a change of share or of place: half the ad at the top and half at the bottom
    /// are the same percentage and a different `visibleRectangle`.
    private func report(_ exposure: Exposure) {
        let rounded = (exposure.share * 100).rounded() / 100
        if isSeen != (rounded > 0) {
            isSeen = rounded > 0
            onSeen?(rounded > 0)
        }
        let place = exposure.visibleBox.integral
        guard rounded != lastPercentage || place != lastVisible else { return }
        lastPercentage = rounded
        lastVisible = place
        onExposure?(Exposure(share: rounded, visibleBox: exposure.visibleBox))
    }

    /// The verdict is final; measuring goes on for the exposure reports and the detachment check.
    private func decide(_ verdict: Verdict) {
        guard self.verdict == nil else { return }
        self.verdict = verdict
        onVerdict?(verdict)
    }
}
