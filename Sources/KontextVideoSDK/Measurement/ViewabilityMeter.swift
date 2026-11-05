import UIKit

/// A measuring loop: every 250 ms (`interval`) it asks how much of the ad's view the viewer can see right now,
/// and turns the answer into a few signals. It decides the one viewability event, the industry's (MRC) rule:
/// `viewable` once at least 50 % of the ad was on screen without a break for 1 s (2 s for a video),
/// `notViewable` when the ad ended before that, `viewUndetermined` when it could not measure.
///
/// ```
/// every 250 ms: tick()
///   ├─ measure:   exposure(of:in:): share on screen (0–1) and the visible rectangle   (static: geometry)
///   ├─ report:    changed? onExposure(share, rect)       → the page, which tells the creative
///   │             any of it seen? changed: onSeen(bool)  → ActiveTimeClock
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
/// The two hard parts. The geometry, `exposure(of:in:)`: the view's corners are carried through every
/// ancestor's transform (rotation, scale), and the shape is cut by every ancestor that clips its subviews and
/// by the window; visible area over full area is the share. Real shapes, not rectangles, so a rotated view is
/// not over-counted. The timing: the 50 % stretch starts again when the share drops, the video pauses, or the
/// loop stalled (a frozen app cannot prove the time was continuous).
///
/// Also here: `canBeSeen` (could the viewer see a view at all, before showing an ad in it), `isInFront`
/// and the 1 % `transparent` threshold.
///
/// Not `ActiveTimeClock`: that one adds up any time seen, with breaks; this one judges the 50 % rule.
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

    /// Exposure changed: percentage on screen and the visible rectangle in the view's coordinates.
    var onExposure: ((Double, CGRect) -> Void)?
    /// The verdict, once.
    var onVerdict: ((Verdict) -> Void)?
    /// The view left the window and did not come back within one interval: the app removed what the ad
    /// sits in, or covered it (UIKit takes a full-screen-covered controller's view out of the window).
    /// On every tick while it stays out, from the second: an owner that waits out a cover hears again once
    /// the cover is gone and the view did not come back.
    var onDetached: (() -> Void)?
    /// Whether something the meter cannot see covers the view while it stays in its window: a sheet presented
    /// over a linear ad (the App Store product page after a click). Asked on every tick; covered reads as 0.
    var isCovered: (() -> Bool)?
    /// The ad became seen (some of it on screen in an active scene) or unseen: the one answer to "is it
    /// seen" the clock and the slot follow. From the first real measurement on, at every change.
    var onSeen: ((Bool) -> Void)?
    /// The view stayed in its window, its scene active, with nothing of it on screen for `offScreenGrace`: a
    /// feed cell swiped away, a view scrolled or moved out of sight. On every tick while that lasts.
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

    /// The ad ended: a verdict is still owed when none was reached.
    func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
        if verdict == nil {
            decide(view == nil ? .viewUndetermined : .notViewable)
        }
    }

    /// One measurement. Internal so tests can drive it with a frozen clock; the timer calls it otherwise.
    func tick() {
        // 1. Did the loop stall (more than two ticks, and at least half a second, since the last: the app froze or
        //    slept)? Then the 50 % stretch cannot be called continuous, and it starts again below.
        let now = Environment.now()
        let stalled = lastTick.map { now - $0 > max(Self.interval * 2, Self.shortestStall) } ?? false
        lastTick = now
        // 2. Is the view still there, in a window? Held weakly: the meter never keeps a view alive.
        guard let view, let window = view.window else {
            if hasMeasured { report(0, visible: .zero) }
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
        let seen = active && isCovered?() != true
        let (percentage, visible) = seen ? Self.exposure(of: view, in: window) : (0, .null)
        // 4. Tell: onExposure when it changed, onSeen when "any of it visible" flipped. First, so the page and
        //    the clock are current before the rules below may end the ad.
        report(percentage, visible: visible.isNull ? .zero : visible)
        // The page's reaction to the exposure may have ended the ad.
        guard !isStopped else { return }
        // 5. Nothing seen for a second while its scene is active: onOffScreen, the ad ends.
        if active, percentage == 0 {
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

    /// At most this opacity (1 %) a view counts as invisible, though it is shown: its alpha times every
    /// ancestor's, as UIKit draws it. Not 0: three ancestors at 0.1 make 0.001, which nobody can see, yet no
    /// single view is transparent; an ad drawn like that (by accident, or to fake views) must not be shown, get
    /// an impression or count as seen. 1 % is invisible to the eye, and far below any fade a real UI rests at.
    nonisolated static let transparent: CGFloat = 0.01

    /// The window `view` is in. A window passed as the container is its own: UIKit gives a window no
    /// `window` of its own.
    static func window(of view: UIView) -> UIWindow? {
        view as? UIWindow ?? view.window
    }

    /// Whether the viewer could see `view`: in a window (or a window itself), with an area, and neither it,
    /// an ancestor nor the window hidden or transparent; transparency multiplies along the chain, as in the
    /// meter. What covers it is not known here; the meter measures that once the ad is shown.
    static func canBeSeen(_ view: UIView) -> Bool {
        guard window(of: view) != nil, view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var opacity: CGFloat = 1
        var node: UIView? = view
        while let current = node {
            opacity *= current.alpha
            if current.isHidden || opacity <= transparent { return false }
            node = current.superview
        }
        return true
    }

    /// Whether `view`'s window is in front of the viewer: the app is active and so is the window's scene
    /// (`foregroundActive`; a window without a scene follows the app). Not with the content in Picture in
    /// Picture only, on the lock screen, with background audio or under Control Center: an impression there
    /// would count an ad nobody sees, and a linear ad would be presented into the background.
    static func isInFront(_ view: UIView) -> Bool {
        guard let window = window(of: view) else { return false }
        return Environment.isWindowActive(window)
    }

    /// The share of `view` that can be seen, and that part's bounding rectangle in the view's coordinates:
    /// its outline cut by the window and by every ancestor that clips (a scroll view, a container with
    /// `clipsToBounds`); nothing when it or an ancestor is hidden or transparent. Measured on the actual
    /// shapes in window coordinates, not on rectangles: a rotated view or ancestor turns a rectangle into a
    /// rotated one, whose bounding box would overstate what is seen. Transparency multiplies along the chain,
    /// as it does on screen: three ancestors at 0.1 leave the ad at 0.001, unseen. Areas compare in window coordinates,
    /// where a scaled ancestor shrinks the whole and the visible part alike. Overlap by sibling views is not
    /// measured: only the view's own outline, its ancestors' clipping and the window count.
    /// The share of `view` on screen now, as the meter measures it: 0 when nothing of it can be seen (outside
    /// the window, clipped away by an ancestor, hidden or transparent).
    static func visibleShare(of view: UIView) -> Double {
        guard let window = view.window else { return 0 }
        return exposure(of: view, in: window).0
    }

    private static func exposure(of view: UIView, in window: UIWindow) -> (Double, CGRect) {
        guard !window.isHidden, window.alpha > Self.transparent else { return (0, .null) }
        let outline = corners(of: view.bounds).map { view.convert($0, to: window) }
        let whole = abs(signedArea(outline))
        guard whole > 0 else { return (0, .null) }
        var visible = clip(outline, to: corners(of: window.bounds))
        var opacity = window.alpha
        var current: UIView? = view
        while let node = current, node !== window, !visible.isEmpty {
            opacity *= node.alpha
            if node.isHidden || opacity <= Self.transparent { return (0, .null) }
            if node !== view, node.clipsToBounds {
                visible = clip(visible, to: corners(of: node.bounds).map { node.convert($0, to: window) })
            }
            current = node.superview
        }
        let seen = abs(signedArea(visible))
        guard seen > 0 else { return (0, .null) }
        let inView = visible.map { view.convert($0, from: window) }
        let xs = inView.map(\.x), ys = inView.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).intersection(view.bounds)
        return (min(1, Double(seen / whole)), box)
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// `subject` cut by the convex polygon `clipper` (Sutherland–Hodgman). Every outline here is the image
    /// of a rectangle under an affine transform, so the clipper is always convex.
    private static func clip(_ subject: [CGPoint], to clipper: [CGPoint]) -> [CGPoint] {
        guard clipper.count >= 3 else { return [] }
        // The clipper's winding decides which side of each edge is inside.
        let sign: CGFloat = signedArea(clipper) >= 0 ? 1 : -1
        var output = subject
        for index in clipper.indices {
            guard !output.isEmpty else { break }
            let edgeStart = clipper[index], edgeEnd = clipper[(index + 1) % clipper.count]
            // Split into typed steps: one expression was too much for the Swift 6.1 type checker (Xcode 16.4).
            let edge = CGVector(dx: edgeEnd.x - edgeStart.x, dy: edgeEnd.y - edgeStart.y)
            let inside = { (point: CGPoint) -> Bool in
                let along: CGFloat = edge.dx * (point.y - edgeStart.y)
                let across: CGFloat = edge.dy * (point.x - edgeStart.x)
                return sign * (along - across) >= 0
            }
            let input = output
            output = []
            for pointIndex in input.indices {
                let current = input[pointIndex], previous = input[(pointIndex + input.count - 1) % input.count]
                if inside(current) {
                    if !inside(previous) { output.append(intersection(previous, current, edgeStart, edgeEnd)) }
                    output.append(current)
                } else if inside(previous) {
                    output.append(intersection(previous, current, edgeStart, edgeEnd))
                }
            }
        }
        return output
    }

    /// The area of a polygon (shoelace formula), its sign the winding: `abs` of it is the area, whatever the
    /// winding. 0 for fewer than three points.
    private static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        var twice: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            twice += a.x * b.y - b.x * a.y
        }
        return twice / 2
    }

    /// Where segment `p1`–`p2` crosses the line through `q1`–`q2`.
    private static func intersection(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> CGPoint {
        let d1 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y), d2 = CGPoint(x: q2.x - q1.x, y: q2.y - q1.y)
        let denominator = d1.x * d2.y - d1.y * d2.x
        guard abs(denominator) > .ulpOfOne else { return p2 }
        let t = ((q1.x - p1.x) * d2.y - (q1.y - p1.y) * d2.x) / denominator
        return CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y)
    }

    /// The page hears about a change of share or of place: half the ad at the top and half at the bottom
    /// are the same percentage and a different `visibleRectangle`.
    private func report(_ percentage: Double, visible: CGRect) {
        let rounded = (percentage * 100).rounded() / 100
        if isSeen != (rounded > 0) {
            isSeen = rounded > 0
            onSeen?(rounded > 0)
        }
        let place = visible.integral
        guard rounded != lastPercentage || place != lastVisible else { return }
        lastPercentage = rounded
        lastVisible = place
        onExposure?(rounded, visible)
    }

    /// The verdict is final; measuring goes on for the exposure reports and the detachment check.
    private func decide(_ verdict: Verdict) {
        guard self.verdict == nil else { return }
        self.verdict = verdict
        onVerdict?(verdict)
    }
}
