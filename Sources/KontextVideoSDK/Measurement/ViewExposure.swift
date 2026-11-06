import UIKit

/// How much of a view the viewer can see, measured on the views themselves: whether it could be seen at all
/// (`canBeSeen`), whether its window is in front of the viewer (`isInFront`), and the share of it on screen
/// (`exposure(of:in:)`). The geometry: the view's corners are carried through every ancestor's transform
/// (rotation, scale), and the shape is cut by every ancestor that clips its subviews and by the window; visible
/// area over full area is the share. Real shapes, not rectangles (`Polygon`), so a rotated view is not
/// over-counted. `ViewabilityMeter` asks it on every tick; `VideoAd` asks it before showing an ad.
@MainActor
enum ViewExposure {
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

    /// The share of `view` on screen now, as the meter measures it: 0 when nothing of it can be seen (outside
    /// the window, clipped away by an ancestor, hidden or transparent).
    static func visibleShare(of view: UIView) -> Double {
        guard let window = window(of: view) else { return 0 }
        return exposure(of: view, in: window).share
    }

    /// The share of `view` that can be seen, and that part's bounding rectangle in the view's coordinates (`Exposure.none` for nothing):
    /// its outline cut by the window and by every ancestor that clips (a scroll view, a container with
    /// `clipsToBounds`); nothing when it or an ancestor is hidden or transparent. Measured on the actual
    /// shapes in window coordinates, not on rectangles: a rotated view or ancestor turns a rectangle into a
    /// rotated one, whose bounding box would overstate what is seen. Transparency multiplies along the chain,
    /// as it does on screen: three ancestors at 0.1 leave the ad at 0.001, unseen. Areas compare in window coordinates,
    /// where a scaled ancestor shrinks the whole and the visible part alike. Overlap by sibling views is not
    /// measured: only the view's own outline, its ancestors' clipping and the window count.
    static func exposure(of view: UIView, in window: UIWindow) -> Exposure {
        guard !window.isHidden, window.alpha > transparent else { return .none }
        let outline = Polygon.corners(of: view.bounds).map { view.convert($0, to: window) }
        let whole = Polygon.area(outline)
        guard whole > 0 else { return .none }
        var visible = Polygon.clip(outline, to: Polygon.corners(of: window.bounds))
        var opacity = window.alpha
        var current: UIView? = view
        while let node = current, node !== window, !visible.isEmpty {
            opacity *= node.alpha
            if node.isHidden || opacity <= transparent { return .none }
            if node !== view, node.clipsToBounds {
                visible = Polygon.clip(visible, to: Polygon.corners(of: node.bounds).map { node.convert($0, to: window) })
            }
            current = node.superview
        }
        let seen = Polygon.area(visible)
        guard seen > 0 else { return .none }
        let inView = visible.map { view.convert($0, from: window) }
        let xs = inView.map(\.x), ys = inView.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).intersection(view.bounds)
        // Explicit, not left to `min`'s argument order: a degenerate transform can make the ratio NaN or infinite.
        let share = Double(seen / whole)
        guard share.isFinite, box.width.isFinite, box.height.isFinite else { return .none }
        return Exposure(share: min(1, max(0, share)), visibleBox: box)
    }
}

/// How much of a view is on screen at one moment.
struct Exposure: Equatable {
    /// The share of the view on screen, 0–1.
    let share: Double
    /// The visible part's bounding rectangle in the view's coordinates; `.null` when nothing is seen.
    let visibleBox: CGRect

    /// Nothing of the view on screen.
    static let none = Exposure(share: 0, visibleBox: .null)
}
