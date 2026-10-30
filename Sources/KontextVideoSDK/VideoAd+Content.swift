/// An overlay lives only while the content plays, when the `VideoAds` tracks a player (`track(_:)`): a
/// pause, the end of the content or another item ends it as `.interrupted`, its `duration` counts seconds
/// of video, and it cannot be shown over paused content. Without a tracked player it runs on active time,
/// as before.
extension VideoAd {
    /// This overlay follows the content: its `VideoAds` tracks a player that is still alive.
    var followsContent: Bool { format == .overlay && owner?.playback.isTracking == true }

    /// `show(in:)` on an overlay over paused content: `contentPaused`, and the ad stays ready.
    func checkContentPlaying() throws {
        guard followsContent, owner?.playback.isPlaying == false else { return }
        Logger.warning("ad \(id.prefix(8)): cannot show the overlay, the content is paused")
        throw VideoAdError.contentPaused
    }

    /// The overlay is on screen: its `duration`, if any, counts from the playhead now.
    func startFollowingContent() {
        guard followsContent, let duration, let owner else { return }
        contentProgress = ContentProgress(duration: duration, at: owner.playback.playhead)
    }

    /// The tracked player changed or a tick came. Only an overlay on screen cares.
    func contentDidChange(_ change: ContentPlayback.Change) {
        guard format == .overlay, isPresented, !hasEnded, let playback = owner?.playback, playback.isTracking else { return }
        if change == .contentChanged {
            Logger.info("ad \(id.prefix(8)): the player moved to other content; the overlay ends")
            end(.interrupted)
            return
        }
        guard playback.isPlaying else {
            Logger.info("ad \(id.prefix(8)): the content paused; the overlay ends")
            end(.interrupted)
            return
        }
        guard change == .tick, let contentProgress else { return }
        // Seconds of video while the overlay is seen: not while its scene is inactive.
        if contentProgress.advance(to: playback.playhead, counting: clock?.isCounting == true) {
            Logger.debug("ad \(id.prefix(8)): overlay duration of \(contentProgress.duration) s of video elapsed")
            isCompleted = true
            end(.completed)
        }
    }

    /// Before another ad's `show`: an overlay over content that no longer plays ends first, so a pause ad
    /// shown right after `player.pause()` finds the screen free, whatever the order of the callbacks.
    func endIfContentStopped() {
        guard format == .overlay, isPresented, !hasEnded, followsContent, owner?.playback.isPlaying == false else { return }
        Logger.info("ad \(id.prefix(8)): the content paused; the overlay ends for the next ad")
        end(.interrupted)
    }
}
