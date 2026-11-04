import Foundation
@testable import KontextVideoSDK
import UIKit

/// What the tests read on an ad that now lives in its content rule or its screen: the old names, kept here so
/// the SDK carries no code only tests use (`swiftlint analyze` flags it there).
@MainActor
extension VideoAd {
    var hostView: AdHostView? { (presentation?.screen as? InlineScreen)?.hostView }
    var linearController: LinearViewController? { (presentation?.screen as? LinearScreen)?.controller }

    /// The tracked player changed or a tick came; the rule decides.
    func contentDidChange(_ change: ContentPlayback.Change) { contentRule.contentDidChange(change) }

    var contentProgress: ContentProgress? { (contentRule as? OverlayRule)?.contentProgress }
    var contentPausedWhileInactive: Bool { (contentRule as? OverlayRule)?.contentPausedWhileInactive ?? false }
    var contentRecheck: Task<Void, Never>? { (contentRule as? OverlayRule)?.contentRecheck }
    static var contentResumeGrace: TimeInterval {
        get { OverlayRule.contentResumeGrace }
        set { OverlayRule.contentResumeGrace = newValue }
    }
}
