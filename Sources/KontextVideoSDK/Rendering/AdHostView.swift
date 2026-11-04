import UIKit

/// What an overlay or pause ad puts into the player's view: a transparent view over the whole player that
/// holds the creative at its place. Covering the player is what lets it follow a resize or a rotation,
/// which only reach a subview through its own bounds; touches outside the creative pass through to the
/// player.
///
/// ```
/// ┌────────── AdHostView = the whole player, e.g. 800×400 ──────────┐
/// │                                                                 │
/// │                (transparent, taps pass through)                 │
/// │                                                                 │
/// │                  ┌──── WebView 320×80 ────┐                     │
/// │                  └────────────────────────┘                     │
/// │                      ↑ above the bottom inset                   │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// The web view is only as big as the ad (its size from the server, shrunk at most to half when it does not
/// fit), placed by `place` at every layout pass, so it follows a resize or a rotation.
@MainActor
final class AdHostView: UIView {
    /// The creative's frame for the player's bounds and safe area, in this view's coordinates; `nil` when
    /// it no longer fits.
    var place: ((CGRect, UIEdgeInsets) -> CGRect?)?
    /// The player became too small for the creative. Once.
    var onUnfit: (() -> Void)?
    /// A full-screen ad: the host fills the player in black and takes every touch on it, the creative sits
    /// inside the safe area, clear of the notch, the island and the home indicator.
    var coversWhole = false {
        didSet { backgroundColor = coversWhole ? .black : .clear }
    }
    let content: UIView

    init(frame: CGRect, content: UIView) {
        self.content = content
        super.init(frame: frame)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.autoresizingMask = []
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Called by UIKit at every layout pass (first show, rotation, resize, safe area change): places the ad.
    override func layoutSubviews() {
        super.layoutSubviews()
        // 1. Ask VideoAd: for this size and the safe area, where does the ad go? The player's safe area, not this
        //    view's: a player may report its own insets.
        guard let place, let player = superview else { return }
        if let frame = place(bounds, player.safeAreaInsets) {
            // 2. It fits: put the web view there, at exactly that size.
            content.frame = frame
        } else if let onUnfit {
            // 3. It no longer fits: tell VideoAd, once (it ends the ad).
            self.onUnfit = nil
            onUnfit()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// Only the creative takes touches; the rest of the player stays the player's, except under a full-screen ad.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self && !coversWhole ? nil : hit
    }
}
