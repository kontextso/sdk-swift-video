import UIKit

/// MRC display viewability for a native ad view: at least 50 % of the ad's
/// pixels on screen for one continuous second, timed (not waited for), while
/// the app is active. Port of `viewability.ts` in video-ad-formats.
///
/// Measurement starts only after the impression (VAST 4.x §3.5.2 — an ad
/// that never rendered reports no viewability at all).
@MainActor
final class ViewabilityMeter {
    static let viewableRatio: CGFloat = 0.5
    static let viewableSeconds: TimeInterval = 1

    private weak var view: UIView?
    private let onVerdict: (AdTracker.Event) -> Void
    private var task: Task<Void, Never>?
    private var decided = false

    init(view: UIView, onVerdict: @escaping (AdTracker.Event) -> Void) {
        self.view = view
        self.onVerdict = onVerdict
    }

    /// Call once the image is painted. Arms the one-second clock; a lapse in
    /// coverage voids the accrued stretch and re-arms on the next check.
    func start() {
        guard task == nil, !decided else { return }
        task = Task { [weak self] in
            var covered: TimeInterval = 0
            let step: TimeInterval = 0.1
            while !Task.isCancelled {
                guard let self else { return }
                covered = self.isVisibleEnough() ? covered + step : 0
                if covered >= Self.viewableSeconds {
                    self.decide(.viewable)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            }
        }
    }

    /// Call when the ad leaves the screen. Undecided → `notViewable`.
    func end() {
        task?.cancel()
        task = nil
        decide(.notViewable)
    }

    private func decide(_ verdict: AdTracker.Event) {
        guard !decided else { return }
        decided = true
        task?.cancel()
        task = nil
        onVerdict(verdict)
    }

    private func isVisibleEnough() -> Bool {
        guard let view, let window = view.window, !view.isHidden, view.alpha > 0.01,
              UIApplication.shared.applicationState == .active else {
            return false
        }
        let frame = view.convert(view.bounds, to: window)
        let visible = frame.intersection(window.bounds)
        guard !visible.isNull, frame.width > 0, frame.height > 0 else { return false }
        let ratio = (visible.width * visible.height) / (frame.width * frame.height)
        return ratio >= Self.viewableRatio
    }
}
