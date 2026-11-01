/// With a player tracked by `track(_:)`, overlay and pause ads follow the content. An overlay lives only
/// while the content plays: a pause, the end of the content, another item, another player or a player that
/// is gone ends it as `.interrupted`; its `duration` counts seconds of video; and it cannot be shown over
/// paused content. A pause ad lives only while the content is paused: once the content plays again, resumed
/// from anywhere (the lock screen, Control Center, a headset, PiP, the app's own code), it ends as
/// `.interrupted`; `.resumed` stays the viewer's Resume on the ad. `.interrupted` has other causes too (the
/// view leaving the window, too little room), so the app reads its player's state rather than the reason.
/// Without a tracked player both run on active time and the app's calls alone.
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
        if format == .pause { return pauseContentDidChange(change) }
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

    /// This pause ad follows the content: its `VideoAds` tracks a player, alive or gone.
    var pauseFollowsContent: Bool { format == .pause && owner?.playback.isTracking == true }

    /// A pause ad is on screen: from here on, content seen playing after it was seen paused ends it. Content
    /// that already played at `show` must pause first: a rate change of playing content is no resume.
    func startFollowingPausedContent() {
        guard pauseFollowsContent, let playback = owner?.playback else { return }
        contentPausedSinceShow = !playback.isPlaying
    }

    /// The tracked player changed or a tick came, for a pause ad on screen: it ends once the content plays
    /// again after a pause, whoever resumed it.
    private func pauseContentDidChange(_ change: ContentPlayback.Change) {
        guard pauseFollowsContent, isPresented, !hasEnded, let playback = owner?.playback else { return }
        let playing: Bool
        switch change {
        case .playback(isPlaying: let value?): playing = value
        case .contentEnded: playing = false
        case .playback(isPlaying: nil), .contentChanged, .jumped, .tick: playing = playback.isPlaying
        }
        endIfContentResumed(playing: playing)
    }

    private func endIfContentResumed(playing: Bool) {
        guard playing else {
            contentPausedSinceShow = true
            return
        }
        guard contentPausedSinceShow else { return }
        Logger.info("ad \(id.prefix(8)): the content plays again; the pause ad ends")
        end(.interrupted)
    }

    /// An ad over content that no longer fits it ends: before another ad's `show`, so a pause ad shown right
    /// after `player.pause()`, or an overlay shown right after `player.play()`, finds the screen free; and,
    /// for an overlay, once its own view is attached, for a pause no callback reported while that ran.
    func endIfContentStopped() {
        if format == .pause {
            guard pauseFollowsContent, isPresented, !hasEnded, let playback = owner?.playback else { return }
            return endIfContentResumed(playing: playback.isPlaying)
        }
        guard format == .overlay, wasShown, !hasEnded, followsContent, owner?.playback.isPlaying == false else { return }
        Logger.info("ad \(id.prefix(8)): the content paused; the overlay ends")
        end(.interrupted)
    }
}
