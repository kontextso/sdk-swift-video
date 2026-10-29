import UIKit

/// What an overlay or pause ad puts into the player's view: a transparent view over the whole player that
/// holds the creative at its place. Covering the player is what lets it follow a resize or a rotation,
/// which only reach a subview through its own bounds; touches outside the creative pass through to the
/// player.
@MainActor
final class AdHostView: UIView {
    /// The creative's frame for the player's bounds and safe area, in this view's coordinates; `nil` when
    /// it no longer fits.
    var place: ((CGRect, UIEdgeInsets) -> CGRect?)?
    /// The player became too small for the creative. Once.
    var onUnfit: (() -> Void)?
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // The player's safe area, not this view's: a player may report its own insets.
        guard let place, let player = superview else { return }
        if let frame = place(bounds, player.safeAreaInsets) {
            content.frame = frame
        } else if let onUnfit {
            self.onUnfit = nil
            onUnfit()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// Only the creative takes touches; the rest of the player stays the player's.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
