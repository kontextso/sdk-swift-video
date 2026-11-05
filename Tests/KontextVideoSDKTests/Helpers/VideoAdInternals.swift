import Foundation
@testable import KontextVideoSDK
import UIKit

/// What the tests read on an ad that now lives in its content rule or its screen: the old names, kept here so
/// the SDK carries no code only tests use (`swiftlint analyze` flags it there).
@MainActor
extension VideoAd {
    var hostView: InlineAdView? { (shownAd?.screen as? InlineScreen)?.hostView }
    var linearController: LinearAdViewController? { (shownAd?.screen as? LinearScreen)?.controller }
    /// The size variant the inline screen chose at `show`.
    var chosenSize: Size? { (shownAd?.screen as? InlineScreen)?.chosenSize }

    /// The tracked player changed or a tick came; the rule decides.
    func contentDidChange(_ change: ContentPlayback.Change) { contentRule.contentDidChange(change) }

    var contentClock: ContentTimeClock? { (contentRule as? OverlayRule)?.contentClock }
    var wasContentPausedWhileInactive: Bool { (contentRule as? OverlayRule)?.wasContentPausedWhileInactive ?? false }
    var contentRecheck: Task<Void, Never>? { (contentRule as? OverlayRule)?.contentRecheck }
    static var contentResumeGrace: TimeInterval {
        get { OverlayRule.contentResumeGrace }
        set { OverlayRule.contentResumeGrace = newValue }
    }
}

/// The reports waiting and the dropped count, now in the reporter's queue: the names the tests read.
@MainActor
extension ErrorReporter {
    var buffer: [ErrorReport] { queue.reports }
    var dropped: Int { queue.dropped }
}
