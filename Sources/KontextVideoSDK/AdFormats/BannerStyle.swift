import UIKit

/// Appearance of an image banner (pause ad, playing overlay).
/// Everything has a default.
public struct BannerStyle: Sendable {
    /// Space between the banner and the container's safe-area edges.
    /// `top` applies for `.top`, `bottom` for `.bottom`; `left`/`right`
    /// always.
    public var margins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    /// Caps the banner width (centered) so it doesn't stretch across
    /// wide players such as iPad or landscape. `nil` = full width.
    public var maxWidth: CGFloat? = nil
    public var cornerRadius: CGFloat = 12
    /// Shown until the image has loaded.
    public var placeholderColor: UIColor = UIColor.black.withAlphaComponent(0.3)

    public init() {}
}

/// Where a banner sits inside the container.
public enum BannerPosition: Sendable {
    case top
    case bottom

    /// The server's `placement.position`, when it names one.
    init?(serverValue: String?) {
        switch serverValue {
        case "top": self = .top
        case "bottom": self = .bottom
        default: return nil
        }
    }
}
