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
    private var lastPercentage = -1.0
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

    /// Stops measuring without a verdict; for the owner's `deinit`, from any thread.
    nonisolated func stopTimer() {
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
        }
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
        let active = Environment.isApplicationActive()
        let frameInWindow = view.convert(view.bounds, to: window)
        let visible = active && !view.isHidden && view.alpha > 0.01 ? frameInWindow.intersection(window.bounds) : .null
        let area = view.bounds.width * view.bounds.height
        let percentage = visible.isNull || area == 0 ? 0 : Double(visible.width * visible.height / area)
        report(percentage, visible: visible.isNull ? .zero : window.convert(visible, to: view))

        let now = ProcessInfo.processInfo.systemUptime
        if percentage >= Self.threshold {
            if exposedSince == nil { exposedSince = now }
            if let since = exposedSince, now - since >= requiredSeconds {
                decide(.viewable)
            }
        } else {
            exposedSince = nil
        }
    }

    private func report(_ percentage: Double, visible: CGRect) {
        let rounded = (percentage * 100).rounded() / 100
        guard rounded != lastPercentage else { return }
        lastPercentage = rounded
        onExposure?(rounded, visible)
    }

    /// The verdict is final; measuring goes on for the exposure reports and the detachment check.
    private func decide(_ verdict: Verdict) {
        guard self.verdict == nil else { return }
        self.verdict = verdict
        onVerdict?(verdict)
    }
}
