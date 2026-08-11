import Foundation

/// The ads prepared for one video — returned by
/// ``VideoSession/startVideo(externalId:title:description:)``.
///
/// Overlay and pause ads are shown automatically via the attached player.
/// The swipe banner is the one format the app must trigger itself, because
/// only the app knows when the swipe happens.
@MainActor
public final class VideoAds {
    /// The publisher's video ID this handle belongs to.
    public let externalId: String

    private weak var session: VideoSession?

    /// Overlay ads prepared for this video, in timeline order.
    public private(set) var overlays: [InstreamAd] = []

    init(externalId: String, session: VideoSession) {
        self.externalId = externalId
        self.session = session
    }

    /// Shows the full-screen swipe banner prepared for this video, if one
    /// was filled. Call it at the moment the user swipes to the next video.
    ///
    /// Called on the handle (not the session) so it is unambiguous which
    /// video the banner belongs to, even if the next episode is already
    /// preloading.
    public func showSwipeBanner() {
        // TODO: the current /ads endpoint serves only overlays; wire this up
        // once the server adds the swipeBanner format.
    }

    // MARK: - Internal

    func apply(_ slots: [InstreamAd]) {
        overlays = slots
    }
}
