import UIKit

/// Where an overlay or pause ad goes in the player's view, as pure arithmetic: a variant scaled down to fit
/// the view's safe area, never enlarged and never below its smallest scale, centred, at the top or the
/// bottom. `VideoAd` picks the variant at `show`; `AdHostView` asks again when the view resizes.
@MainActor
enum AdPlacement {
    /// Below this share of the nominal size a scalable ad is not shown.
    static let minimumScale: CGFloat = 0.5

    /// Where `size` goes inside `fullBounds` less `safeArea`; `nil` when it does not fit.
    static func frame(of size: VideoAd.Size, at position: VideoAd.Position?, in fullBounds: CGRect, safeArea: UIEdgeInsets) -> CGRect? {
        guard let bounds = room(in: fullBounds, safeArea: safeArea) else { return nil }
        let scale = scale(toFit: size, in: bounds)
        guard scale >= smallestScale(of: size) else { return nil }
        let scaled = CGSize(width: (CGFloat(size.width) * scale).rounded(), height: (CGFloat(size.height) * scale).rounded())
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

    /// Whether the viewer could see `view`: in a window, with an area, and neither it, an ancestor nor the
    /// window hidden or transparent. What covers it is not known here; the meter measures that once the ad
    /// is shown.
    static func canBeSeen(_ view: UIView) -> Bool {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 { return false }
            node = current.superview
        }
        return true
    }
}
