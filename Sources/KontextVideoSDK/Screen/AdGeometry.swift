import UIKit

/// The geometry of an overlay or pause ad in the player's view, as pure arithmetic: no views and no ad, only
/// rectangles and scales. Where the ad goes: a variant scaled down to fit the view's safe area, never enlarged
/// and never below its smallest scale, centred, at the top or the bottom. `VideoAd` picks the variant at
/// `show`; `InlineAdView` asks again when the view resizes. Whether the viewer could see a view is
/// `ViewExposure`'s.
@MainActor
enum AdGeometry {
    /// Below this share of the nominal size a scalable ad is not shown.
    static let minimumScale: CGFloat = 0.5

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

    /// The smallest scale a variant may be shown at: half for a scalable ad, full size for a fixed one.
    static func smallestScale(of size: VideoAd.Size) -> CGFloat {
        size.isScalable ? minimumScale : 1
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
}
