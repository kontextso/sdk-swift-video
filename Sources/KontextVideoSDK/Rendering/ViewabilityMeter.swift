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
    /// sits in. Once.
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
    /// Ticks in a row that found no window; the second one reports the detachment.
    private var detachedTicks = 0
    private var detachedReported = false

    init(view: UIView, requiredSeconds: TimeInterval) {
        self.view = view
        self.requiredSeconds = requiredSeconds
    }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops measuring without a verdict; for the owner's `deinit` teardown, which runs on the main actor.
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// The ad ended: a verdict is still owed when none was reached.
    func stop() {
        timer?.invalidate()
        timer = nil
        if verdict == nil {
            decide(view == nil ? .viewUndetermined : .notViewable)
        }
    }

    private func tick() {
        let now = Environment.now()
        let stalled = lastTick.map { now - $0 > Self.interval * 2 } ?? false
        lastTick = now
        guard let view, let window = view.window else {
            report(0, visible: .zero)
            exposedSince = nil
            // One tick of grace: a view re-parented within the same turn of the run loop is not gone.
            detachedTicks += 1
            if view != nil, detachedTicks >= 2, !detachedReported {
                detachedReported = true
                onDetached?()
            }
            return
        }
        detachedTicks = 0
        let visible = Environment.isApplicationActive() ? Self.visibleRect(of: view, in: window) : .null
        let area = view.bounds.width * view.bounds.height
        let percentage = visible.isNull || area == 0 ? 0 : Double(visible.width * visible.height / area)
        report(percentage, visible: visible.isNull ? .zero : window.convert(visible, to: view))

        if percentage >= Self.threshold {
            // A gap between ticks breaks the continuity the rule asks for: the clock starts again.
            if exposedSince == nil || stalled { exposedSince = now }
            if let since = exposedSince, now - since >= requiredSeconds {
                decide(.viewable)
            }
        } else {
            exposedSince = nil
        }
    }

    /// The part of `view` that can be seen, in the window's coordinates: its frame cut by the window and
    /// by every ancestor that clips (a scroll view, a container with `clipsToBounds`); `.null` when it or
    /// an ancestor is hidden or transparent. Overlap by sibling views is not seen; nothing cheap sees it.
    private static func visibleRect(of view: UIView, in window: UIWindow) -> CGRect {
        var rect = view.convert(view.bounds, to: window).intersection(window.bounds)
        var current: UIView? = view
        while let node = current, node !== window {
            if node.isHidden || node.alpha <= 0.01 { return .null }
            if node !== view, node.clipsToBounds {
                rect = rect.intersection(node.convert(node.bounds, to: window))
            }
            if rect.isNull { return .null }
            current = node.superview
        }
        return rect
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
