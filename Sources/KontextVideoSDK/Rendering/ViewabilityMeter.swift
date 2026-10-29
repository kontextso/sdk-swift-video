import UIKit

/// Measures how much of an ad's view is on screen while it is shown, and decides the one viewability
/// event: `viewable` once at least 50 % of the box was on screen for the required continuous time (1 s
/// for an image, 2 s for a video), `notViewable` when the ad ended before that, `viewUndetermined` when
/// it could not measure. Keeps measuring after the verdict, until the ad ends: it also reports exposure
/// changes, which the page relays to the creative, and notices the view leaving the window.
@MainActor
final class ViewabilityMeter {
    enum Verdict: String {
        case viewable
        case notViewable
        case viewUndetermined
    }

    /// How often the box is measured. A constant in spirit; a variable so the tests can shrink it.
    static var interval: TimeInterval = 0.25
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
    private var stopped = false
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
        guard timer == nil, !stopped else { return }
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

    /// Stops measuring without a verdict; for the owner's `deinit` teardown, which runs on the main actor.
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// The ad ended: a verdict is still owed when none was reached.
    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        if verdict == nil {
            decide(view == nil ? .viewUndetermined : .notViewable)
        }
    }

    /// One measurement. Internal so tests can drive it with a frozen clock; the timer calls it otherwise.
    func tick() {
        let now = Environment.now()
        let stalled = lastTick.map { now - $0 > Self.interval * 2 } ?? false
        lastTick = now
        guard let view, let window = view.window else {
            report(0, visible: .zero)
            exposedSince = nil
            // One tick of grace: a view re-parented within the same turn of the run loop is not gone.
            detachedTicks += 1
            if view != nil, detachedTicks >= 2 {
                onDetached?()
            }
            return
        }
        detachedTicks = 0
        // The ad's own scene, not the app: an iPad window in the background shows nothing.
        let (percentage, visible) = Environment.isWindowActive(window) ? Self.exposure(of: view, in: window) : (0, .null)
        report(percentage, visible: visible.isNull ? .zero : visible)
        // The page's reaction to the exposure may have ended the ad.
        guard !stopped else { return }

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

    /// The share of `view` that can be seen, and that part's bounding rectangle in the view's coordinates:
    /// its outline cut by the window and by every ancestor that clips (a scroll view, a container with
    /// `clipsToBounds`); nothing when it or an ancestor is hidden or transparent. Measured on the actual
    /// shapes in window coordinates, not on rectangles: a rotated view or ancestor turns a rectangle into a
    /// rotated one, whose bounding box would overstate what is seen. Areas compare in window coordinates,
    /// where a scaled ancestor shrinks the whole and the visible part alike. Overlap by sibling views is not
    /// seen; nothing cheap sees it.
    private static func exposure(of view: UIView, in window: UIWindow) -> (Double, CGRect) {
        guard !window.isHidden, window.alpha > 0.01 else { return (0, .null) }
        let outline = corners(of: view.bounds).map { view.convert($0, to: window) }
        let whole = area(of: outline)
        guard whole > 0 else { return (0, .null) }
        var visible = clip(outline, to: corners(of: window.bounds))
        var current: UIView? = view
        while let node = current, node !== window, !visible.isEmpty {
            if node.isHidden || node.alpha <= 0.01 { return (0, .null) }
            if node !== view, node.clipsToBounds {
                visible = clip(visible, to: corners(of: node.bounds).map { node.convert($0, to: window) })
            }
            current = node.superview
        }
        let seen = area(of: visible)
        guard seen > 0 else { return (0, .null) }
        let inView = visible.map { view.convert($0, from: window) }
        let xs = inView.map(\.x), ys = inView.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).intersection(view.bounds)
        return (min(1, Double(seen / whole)), box)
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// The area of a polygon (shoelace formula), whatever its winding.
    private static func area(of polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        var twice: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
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
