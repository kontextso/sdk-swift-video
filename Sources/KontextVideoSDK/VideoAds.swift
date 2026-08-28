import Foundation

/// The ads prepared for one video — returned by
/// ``VideoSession/startVideo(externalId:title:description:)``.
///
/// One placement object per format. The app decides when ads appear; the
/// SDK does not observe the player:
///
/// ```swift
/// // on pause
/// if ads.pauseOverlay.isReady { ads.pauseOverlay.show(in: playerView) }
/// // on resume
/// ads.pauseOverlay.hide()
/// ```
///
/// Each ad is shown once; afterwards `isReady` is `false` until the next
/// ``VideoSession/startVideo(externalId:title:description:)``.
@MainActor
public final class VideoAds {
    /// The publisher's video ID this handle belongs to.
    public let externalId: String

    /// Banner over part of the paused player.
    public let pauseOverlay: PauseOverlayAd

    /// Image over the whole paused player, with a Resume button.
    public let pauseFullscreen: PauseFullscreenAd

    init(externalId: String, emit: @escaping (VideoAdEvent) -> Void) {
        self.externalId = externalId
        self.pauseOverlay = PauseOverlayAd(externalId: externalId, emit: emit)
        self.pauseFullscreen = PauseFullscreenAd(externalId: externalId, emit: emit)
    }

    func apply(_ ads: [VideoAd]) {
        pauseOverlay.apply(ads.filter { $0.format == .pauseOverlay })
        pauseFullscreen.apply(ads.filter { $0.format == .pauseFullscreen })
    }
}
