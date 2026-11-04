import UIKit

/// Where an overlay or pause ad goes in the player's view, as pure arithmetic: a variant scaled down to fit
/// the view's safe area, never enlarged and never below its smallest scale, centred, at the top or the
/// bottom. `VideoAd` picks the variant at `show`; `AdHostView` asks again when the view resizes.
@MainActor
enum AdPlacement {
    /// Below this share of the nominal size a scalable ad is not shown.
    static let minimumScale: CGFloat = 0.5

    /// At most this opacity (1 %) a view counts as invisible, though it is shown: its alpha times every
    /// ancestor's, as UIKit draws it. Not 0: three ancestors at 0.1 make 0.001, which nobody can see, yet no
    /// single view is transparent; an ad drawn like that (by accident, or to fake views) must not be shown, get
    /// an impression or count as seen. 1 % is invisible to the eye, and far below any fade a real UI rests at.
    nonisolated static let transparent: CGFloat = 0.01

    /// Where `size` goes inside `fullBounds` less `safeArea`; `nil` when it does not fit.
    static func frame(of size: VideoAd.Size, at position: VideoAd.Position?, in fullBounds: CGRect, safeArea: UIEdgeInsets) -> CGRect? {
        // 1. The free space: the view less the safe area and the app's insets. Nothing left: it does not fit.
        guard let bounds = room(in: fullBounds, safeArea: safeArea) else { return nil }
        // 2. The largest scale at which the ad fits that space, at most 1 (full size, never enlarged).
        let scale = scale(toFit: size, in: bounds)
        // 3. It would have to shrink below its limit (half, or not at all for a fixed ad): it does not fit.
        guard scale >= smallestScale(of: size) else { return nil }
        // 4. Its size in points at that scale.
        let scaled = CGSize(width: (CGFloat(size.width) * scale).rounded(), height: (CGFloat(size.height) * scale).rounded())
        // 5. Centred across, at the top or the bottom (the default) of the free space.
        let x = (bounds.minX + (bounds.width - scaled.width) / 2).rounded()
        let y = position == .top ? bounds.minY : bounds.maxY - scaled.height
        return CGRect(x: x, y: y, width: scaled.width, height: scaled.height)
    }

    /// What `safeArea` leaves of `fullBounds`; `nil` when it leaves no area. Insets wider or taller than the
    /// view make an inverted rectangle, whose `width` and `height` `CGRect` reads as positive: checked here
    /// on the raw arithmetic, finite too, so a huge inset never reaches a size or a log.
    static func room(in fullBounds: CGRect, safeArea: UIEdgeInsets) -> CGRect? {
        let width = fullBounds.size.width - safeArea.left - safeArea.right
        let height = fullBounds.size.height - safeArea.top - safeArea.bottom
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGRect(x: fullBounds.origin.x + safeArea.left, y: fullBounds.origin.y + safeArea.top, width: width, height: height)
    }

    /// The scale at which `size` fits `bounds`, at most 1: never enlarged.
    static func scale(toFit size: VideoAd.Size, in bounds: CGRect) -> CGFloat {
        min(1, bounds.width / CGFloat(size.width), bounds.height / CGFloat(size.height))
    }

    /// How far a variant may shrink: to `minimumScale`, or not at all when the creative is not scalable.
    static func smallestScale(of size: VideoAd.Size) -> CGFloat {
        size.scalable ? minimumScale : 1
    }

    /// The app's insets with a negative or non-finite side counted as zero.
    static func cleaned(_ insets: UIEdgeInsets) -> UIEdgeInsets {
        let side = { (value: CGFloat) in value.isFinite ? max(0, value) : 0 }
        return UIEdgeInsets(top: side(insets.top), left: side(insets.left), bottom: side(insets.bottom), right: side(insets.right))
    }

    /// The safe area with the app's insets added on every side.
    static func adding(_ insets: UIEdgeInsets, to safeArea: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: safeArea.top + insets.top, left: safeArea.left + insets.left,
                     bottom: safeArea.bottom + insets.bottom, right: safeArea.right + insets.right)
    }

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
}
