import Foundation

/// A pause ad lives only while the content is paused: once the content plays again, resumed from anywhere
/// (the lock screen, Control Center, a headset, PiP, the app's own code), it ends as `.interrupted`;
/// `.resumed` stays the viewer's Resume on the ad. It ends at once when its episode is gone from the
/// player: another `VideoAds` took the player (the next page of a feed sharing one player) or it plays
/// another item. Shown on, it would hold the app's one slot over content it is not for.
@MainActor
final class PauseRule: ContentRule {
    unowned let ad: VideoAd

    /// The content was seen paused since `show`: from then on, content seen playing ends the ad.
    private(set) var hasContentPausedSinceShow = false

    init(ad: VideoAd) {
        self.ad = ad
    }

    /// This pause ad follows the content: its `VideoAds` tracks a player, alive or gone.

    var refusesShow: Bool { false }

    var checksEpisode: Bool { true }

    /// A pause ad has no `duration`: nothing ends it on time.
    var wallClockDuration: TimeInterval? { nil }

    /// A pause ad is on screen: from here on, content seen playing after it was seen paused ends it. Content
    /// that already played at `show` must pause first: a rate change of playing content is no resume.
    func started(onScreenClock clock: OnScreenTimeClock) {
        guard ad.isTrackingContent, let playback = ad.contentPlayback else { return }
        hasContentPausedSinceShow = !playback.isPlaying
    }

    func contentDidChange(_ change: ContentPlayback.Change) {
        guard ad.isTrackingContent, ad.state.wasOnScreen, !ad.hasEnded, let playback = ad.contentPlayback else { return }
        let isPlaying: Bool
        switch change {
        case .contentChanged:
            Logger.info("ad \(ad.id.prefix(8)): the content changed or another VideoAds took the player; the pause ad ends")
            return ad.end(.interrupted)
        case .playingChanged(isPlaying: let value?): isPlaying = value
        case .contentEnded: isPlaying = false
        case .playingChanged(isPlaying: nil), .seeked, .tick: isPlaying = playback.isPlaying
        }
        endIfContentResumed(isPlaying: isPlaying)
    }

    /// A pause ad shown right before `player.play()` ends at the next ad's `show`, which finds the slot free.
    func endIfContentStopped() {
        guard ad.isTrackingContent, ad.state.wasOnScreen, !ad.hasEnded, let playback = ad.contentPlayback else { return }
        endIfContentResumed(isPlaying: playback.isPlaying)
    }

    func cancel() {}

    private func endIfContentResumed(isPlaying: Bool) {
        guard isPlaying else {
            hasContentPausedSinceShow = true
            return
        }
        guard hasContentPausedSinceShow else { return }
        Logger.info("ad \(ad.id.prefix(8)): the content plays again; the pause ad ends")
        ad.end(.interrupted)
    }
}
