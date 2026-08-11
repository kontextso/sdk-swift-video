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

    /// Render-ready creatives keyed by bidId. Filled as they arrive — the
    /// server writes ad copy asynchronously after the ads response.
    public private(set) var creatives: [String: InstreamAdCreative] = [:]

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
        session?.presentSwipeBanner(for: self)
    }

    // MARK: - Internal

    func apply(_ slots: [InstreamAd]) {
        overlays = slots
    }

    func setCreative(_ creative: InstreamAdCreative, forBidId bidId: String) {
        creatives[bidId] = creative
    }
}
