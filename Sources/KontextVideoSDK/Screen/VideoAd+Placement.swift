import UIKit

/// Where an overlay or pause ad goes in the player's view. Two layers: this file decides, `AdGeometry`
/// calculates.
///
/// ```
/// VideoAd.show(in: view, insets:)   ─┐
/// AdHostView.layoutSubviews (each)  ─┤
///                                    ▼
/// ┌─ VideoAd+Placement (knows this ad) ────────────────────────────┐
/// │  frame(in:safeArea:)   which variant, and where   (at show)    │
/// │  refit(in:safeArea:)   where it goes now          (each pass)  │
/// │  tooSmall              the containerTooSmall error             │
/// │  fullscreenFrame       full-screen pause ad: view less its     │
/// │                        safe area                               │
/// └──────────────────────────────┬─────────────────────────────────┘
///                                │ asks with plain numbers
///                                ▼
/// ┌─ AdGeometry (knows no ad, pure arithmetic) ────────────────────┐
/// │  room           the view less the safe area and insets         │
/// │  scale          how much the ad must shrink, at most 1         │
/// │  smallestScale  0.5, or 1 for a fixed ad                       │
/// │  frame          the rectangle: room, scale, check, place       │
/// │  adding         the app's insets on top of the safe area       │
/// └────────────────────────────────────────────────────────────────┘
/// ```
///
/// 1. At `show`, once: `frame(in:safeArea:)`. `AdGeometry.room` gives the free space (none:
///    `containerTooSmall`). For each size variant from the server `AdGeometry.scale` says how much it would
///    shrink; the pick is the biggest variant that fits at full size, else the one that shrinks least within its
///    limit, else the closest (which then fails). `AdGeometry.frame` checks it; `nil`: `tooSmall` and `show`
///    throws, the ad stays ready. The pick is kept as `chosenSize`.
/// 2. At every layout pass of `AdHostView`: `refit(in:safeArea:)`. A full-screen pause ad takes the view less
///    its safe area, no variants. Otherwise `AdGeometry.frame` of `chosenSize`, inside the safe area plus the
///    app's insets, gives where `AdHostView` puts the web view; `nil`: it no longer fits, `AdHostView` calls
///    `onUnfit` and the ad ends `.interrupted`.
///
/// Example: variants 320×80 and 300×50 pt, an inline player of 393×221 pt, the app's controls 44 pt at the
/// bottom. The room is 393×177; both variants fit at full size, so the biggest: 320×80, centred, just above
/// the controls. Rotated to a full-screen player, `refit` runs again: same variant, new numbers.
///
/// The split keeps `AdGeometry` testable with numbers alone, and the ad's rules (variants, full screen,
/// errors, logs) here.
extension VideoAd {
    /// Where the ad goes in the player's view: the best variant for the box, scaled down to fit, never
    /// below 50 %, and not at all for a variant marked not scalable. Picks the variant first (the largest that fits without scaling, else the best scale),
    /// so a player that changed shape between `load` and `show` gets the size built for it. A card or
    /// strip stays inside the view's safe area: a full-screen player runs under the notch and the home
    /// indicator, and an ad there is partly hidden and hard to tap. A full-screen pause ad fills the
    /// whole view; its page keeps its own controls clear of those areas.
    func frame(in fullBounds: CGRect, safeArea: UIEdgeInsets) throws -> CGRect {
        guard descriptor.position != .fullscreen, let defaultSize = descriptor.size else { return fullBounds }
        guard let bounds = AdGeometry.room(in: fullBounds, safeArea: safeArea) else {
            chosenSize = nil
            throw tooSmall(for: defaultSize, room: nil, safeArea: safeArea)
        }
        let fit = { (candidate: Size) in AdGeometry.scale(toFit: candidate, in: bounds) }
        let unscaled = descriptor.sizes.filter { fit($0) >= 1 }
        let usable = descriptor.sizes.filter { fit($0) >= AdGeometry.smallestScale(of: $0) }
        let size = unscaled.max { $0.width * $0.height < $1.width * $1.height }
            ?? usable.max { fit($0) < fit($1) }
            ?? descriptor.sizes.max { fit($0) < fit($1) }
            ?? defaultSize
        chosenSize = size
        if size != defaultSize { Logger.debug("ad \(id.prefix(8)): size \(size.width)\u{00D7}\(size.height) chosen for a \(Int(bounds.width))\u{00D7}\(Int(bounds.height)) view") }
        guard let frame = AdGeometry.frame(of: size, at: descriptor.position, in: fullBounds, safeArea: safeArea) else {
            chosenSize = nil
            throw tooSmall(for: size, room: bounds, safeArea: safeArea)
        }
        return frame
    }

    /// `containerTooSmall` with the view that holds `size`, safe area and insets included. `room` is what
    /// they left of the view, `nil` when they left nothing.
    func tooSmall(for size: Size, room: CGRect?, safeArea: UIEdgeInsets) -> VideoAdError {
        let smallest = AdGeometry.smallestScale(of: size)
        let minimum = CGSize(width: (CGFloat(size.width) * smallest).rounded(.up) + safeArea.left + safeArea.right,
                             height: (CGFloat(size.height) * smallest).rounded(.up) + safeArea.top + safeArea.bottom)
        let view = room.map { "view \(Int($0.width))×\(Int($0.height)) is too small for" } ?? "the safe area and insets leave no room for"
        Logger.warning("ad \(id.prefix(8)): \(view) the ad's \(size.width)×\(size.height)\(size.isScalable ? " at 50 %" : ", which may not shrink"); the ad stays ready")
        return VideoAdError.containerTooSmall(minimum: minimum)
    }

    /// The chosen variant fitted again to a view that resized or rotated: the page was told that variant,
    /// so only its scale changes. `nil` when it no longer fits.
    func refit(in fullBounds: CGRect, safeArea: UIEdgeInsets) -> CGRect? {
        if descriptor.position == .fullscreen { return fullscreenFrame(in: fullBounds, safeArea: safeArea) }
        guard let size = chosenSize else { return fullBounds }
        return AdGeometry.frame(of: size, at: descriptor.position, in: fullBounds, safeArea: AdGeometry.adding(extraInsets, to: safeArea))
    }

    /// A full-screen pause ad's page: the player less its safe area (the notch or island, the home indicator,
    /// a landscape cutout), so its text and controls stay clear of them; the host fills the rest in black.
    /// The app's insets do not apply. A safe area that leaves nothing gives the whole player.
    func fullscreenFrame(in fullBounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        AdGeometry.room(in: fullBounds, safeArea: safeArea) ?? fullBounds
    }
}
