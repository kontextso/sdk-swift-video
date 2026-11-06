@testable import KontextVideoSDK
import Testing
import UIKit

/// How much of a view is on screen, against real views in a window: a degenerate transform measures nothing, a
/// huge one a finite share, and what cannot be seen (no size, hidden, transparent, no window) is not.
/// Serialized: it puts views in a window.
extension SerialSuites {
@Suite
@MainActor
struct ViewExposureTests {
    private let window = TestWindow(size: CGSize(width: 400, height: 800))

    private func view(_ transform: CGAffineTransform) -> UIView {
        let view = UIView(frame: CGRect(x: 50, y: 50, width: 200, height: 100))
        window.add(view)
        view.transform = transform
        return view
    }

    @Test func degenerateTransformsMeasureNothing() {
        defer { window.tearDown() }
        for transform in [CGAffineTransform(scaleX: 0, y: 0), CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0),
                          CGAffineTransform(translationX: .infinity, y: 0)] {
            #expect(ViewExposure.exposure(of: view(transform), in: window.window) == .none, "\(transform)")
        }
    }

    @Test func aHugeScaleGivesAFiniteShare() {
        defer { window.tearDown() }
        let exposure = ViewExposure.exposure(of: view(CGAffineTransform(scaleX: 1e300, y: 1e300)), in: window.window)
        #expect(exposure.share.isFinite && (0...1).contains(exposure.share))
        #expect(exposure.visibleBox.isNull || (exposure.visibleBox.width.isFinite && exposure.visibleBox.height.isFinite))
    }

    @Test func whatCannotBeSeenIsNot() {
        defer { window.tearDown() }
        let plain = view(.identity)
        #expect(ViewExposure.canBeSeen(plain) && ViewExposure.exposure(of: plain, in: window.window).share == 1)
        let empty = UIView(frame: .zero)
        window.add(empty)
        #expect(!ViewExposure.canBeSeen(empty), "no size")
        let parent = UIView(frame: CGRect(x: 0, y: 300, width: 300, height: 300))
        window.add(parent)
        let child = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        parent.addSubview(child)
        parent.isHidden = true
        #expect(!ViewExposure.canBeSeen(child), "a hidden ancestor")
        parent.isHidden = false
        parent.alpha = 0.2
        child.alpha = 0.04
        #expect(ViewExposure.exposure(of: child, in: window.window) == .none, "0.2 × 0.04 is under 1 %")
        #expect(!ViewExposure.canBeSeen(UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))), "no window")
    }
}
}
