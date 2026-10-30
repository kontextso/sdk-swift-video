/// An overlay lives only while the content plays, when the `VideoAds` tracks a player (`track(_:)`): a
/// pause, the end of the content, another item, another player or a player that is gone ends it as
/// `.interrupted`; its `duration` counts seconds of video; and it cannot be shown over paused content.
/// Without a tracked player it runs on active time, as before.
extension VideoAd {
    /// This overlay follows the content: its `VideoAds` tracks a player, alive or gone.
    var followsContent: Bool { format == .overlay && owner?.playback.isTracking == true }

    /// The app code a `show` runs before its checks: an overlay over stopped content ends (its `didEnd`), and
    /// the player is read. Every check after it sees what that code left. Returns whether this overlay's
    /// content is paused.
    func runAppCodeBeforeShow() -> Bool {
        // An ad already shown leaves the ad on screen alone; `show` throws `alreadyShown` right after.
        if !wasShown { KontextVideo.shared.adOnScreen?.endIfContentStopped() }
        guard followsContent, owner?.playback.isPlaying == false else { return false }
        Logger.warning("ad \(id.prefix(8)): cannot show the overlay, the content is paused")
        return true
    }

    /// The overlay is on screen: its `duration`, if any, counts from the playhead now, and starts again from
    /// the playhead whenever its scene comes back: video played while it could not be seen counts nothing.
    func startFollowingContent() {
        guard followsContent, let duration, let owner else { return }
        contentProgress = ContentProgress(duration: duration, at: owner.playback.playhead)
        clock?.onActivate = { [weak self] in
            guard let self, let playback = self.owner?.playback else { return }
            contentProgress?.resync(to: playback.playhead)
        }
    }

    /// The tracked player changed or a tick came. An overlay cares from the moment `show` reserved it: a
    /// pause while its view is being attached ends it before any impression.
    func contentDidChange(_ change: ContentPlayback.Change) {
        guard followsContent, wasShown, !hasEnded, let playback = owner?.playback else { return }
        switch change {
        case .contentChanged, .contentEnded:
            Logger.info("ad \(id.prefix(8)): the content ended or changed; the overlay ends")
            end(.interrupted)
            return
        case .playback(isPlaying: false):
            Logger.info("ad \(id.prefix(8)): the content paused; the overlay ends")
            end(.interrupted)
            return
        case .jumped:
            contentProgress?.resync(to: playback.playhead)
            return
        case .playback, .tick:
            break
        }
        guard playback.isPlaying else {
            Logger.info("ad \(id.prefix(8)): the content paused or its player is gone; the overlay ends")
            end(.interrupted)
            return
        }
        guard change == .tick, let contentProgress, !hasEnded else { return }
        // Seconds of video while the overlay is seen: not while its scene is inactive.
        if contentProgress.advance(to: playback.playhead, counting: clock?.isCounting == true, rate: playback.rate) {
            Logger.debug("ad \(id.prefix(8)): overlay duration of \(contentProgress.duration) s of video elapsed")
            isCompleted = true
            end(.completed)
        }
    }

    /// An overlay over content that no longer plays ends: before another ad's `show`, so a pause ad shown
    /// right after `player.pause()` finds the screen free, and once its own view is attached, for a pause
    /// no callback reported while that ran.
    func endIfContentStopped() {
        guard format == .overlay, wasShown, !hasEnded, followsContent, owner?.playback.isPlaying == false else { return }
        Logger.info("ad \(id.prefix(8)): the content paused; the overlay ends")
        end(.interrupted)
    }
}
