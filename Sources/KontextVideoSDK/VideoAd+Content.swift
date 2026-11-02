import Foundation

/// With a player tracked by `track(_:)`, overlay and pause ads follow the content. An overlay lives only
/// while the content plays: a pause, the end of the content, another item, another player or a player that
/// is gone ends it as `.interrupted`; its `duration` counts seconds of video; and it cannot be shown over
/// paused content. A pause while the overlay's scene is not active (the app in the background, where iOS
/// pauses the player itself and apps often pause their own) does not end it: the overlay freezes, as its
/// clock does, and once the scene is active again the content has `contentResumeGrace` to play again
/// before that pause ends it as any other. A pause ad lives only while the content is paused: once the
/// content plays again, resumed from anywhere (the lock screen, Control Center, a headset, PiP, the app's
/// own code), it ends as `.interrupted`; `.resumed` stays the viewer's Resume on the ad. `.interrupted` has other causes too (the
/// view leaving the window, too little room), so the app reads its player's state rather than the reason.
/// Without a tracked player both run on active time and the app's calls alone.
extension VideoAd {
    /// How long, once its scene is active again, an overlay frozen by a pause in the background waits for
    /// the app to play the content again before the pause ends it. Tests shorten it.
    static var contentResumeGrace: TimeInterval = 1

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
    /// A pause while the scene was away is checked again once it is back.
    func startFollowingContent() {
        guard followsContent, let owner else { return }
        if let duration { contentProgress = ContentProgress(duration: duration, at: owner.playback.playhead) }
        clock?.onActivate = { [weak self] in
            guard let self, let playback = self.owner?.playback else { return }
            contentProgress?.resync(to: playback.playhead)
            if contentPausedWhileInactive { recheckContentAfterGrace() }
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
            if freezesOnPause() { return }
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
            if freezesOnPause() { return }
            Logger.info("ad \(id.prefix(8)): the content paused or its player is gone; the overlay ends")
            end(.interrupted)
            return
        }
        if contentPausedWhileInactive {
            // The content plays again: the frozen overlay goes on where it stopped.
            Logger.info("ad \(id.prefix(8)): the content plays again; the overlay goes on")
            contentPausedWhileInactive = false
            contentRecheck?.cancel()
            contentRecheck = nil
        }
        guard change == .tick, let contentProgress, !hasEnded else { return }
        // Seconds of video while the overlay is seen: not while its scene is inactive or it is out of sight.
        if contentProgress.advance(to: playback.playhead, counting: clock?.isCounting == true, rate: playback.rate) {
            Logger.debug("ad \(id.prefix(8)): overlay duration of \(contentProgress.duration) s of video elapsed")
            isCompleted = true
            end(.completed)
        }
    }

    /// A pause while the overlay's scene is not active freezes the overlay instead of ending it: leaving the
    /// app pauses an `AVPlayer` and, often, the app's own player, and the viewer coming back expects the
    /// overlay still there. It stays frozen, whatever the content reports, until the content plays again or
    /// the check after the scene's return. Returns whether the overlay stays. Before its clock exists (the
    /// view still being attached) a pause ends it as always.
    private func freezesOnPause() -> Bool {
        if clock?.isSceneActive == false, !contentPausedWhileInactive {
            Logger.info("ad \(id.prefix(8)): the content paused while the scene is not active; the overlay freezes")
            contentPausedWhileInactive = true
        }
        return contentPausedWhileInactive
    }

    /// The scene is back over an overlay frozen by a pause: the app may be about to play the content again,
    /// so the pause is read once more after `contentResumeGrace`. Still paused, with the scene still active,
    /// the overlay ends as on any pause; a scene that left again waits for its next return.
    private func recheckContentAfterGrace() {
        contentRecheck?.cancel()
        contentRecheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.contentResumeGrace * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            contentRecheck = nil
            guard followsContent, !hasEnded, contentPausedWhileInactive, clock?.isSceneActive == true,
                  let playback = owner?.playback else { return }
            contentPausedWhileInactive = false
            if playback.isPlaying {
                Logger.info("ad \(id.prefix(8)): the content plays again; the overlay goes on")
                return
            }
            Logger.info("ad \(id.prefix(8)): the content is still paused after the scene came back; the overlay ends")
            end(.interrupted)
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

    /// Runs `work` with the content playhead read once, before it. The app's player (`currentTime`) is the one
    /// piece of app code a beacon calls; read here it sees the ad before the operation changes anything, and
    /// every beacon inside uses that value. Nested calls share the outer read; nothing is read when no URL
    /// asks for it (`urls`: the operation's, a click's destinations). While the player is read, the last value
    /// is the frozen one: an operation it starts reads nothing more, so a player that ends the ad cannot recurse.
    @discardableResult
    func withContentPlayhead<T>(alsoFor urls: [URL] = [], _ work: () throws -> T) rethrows -> T {
        let asked = tracker.readsContentPlayhead || urls.contains { Tracker.asksForContentPlayhead($0.absoluteString) }
        guard tracker.frozenContentPlayhead == nil, asked else { return try work() }
        tracker.frozenContentPlayhead = tracker.lastContentPlayhead
        defer { tracker.frozenContentPlayhead = nil }
        let playhead = tracker.contentPlayhead()
        tracker.lastContentPlayhead = playhead
        tracker.frozenContentPlayhead = playhead
        return try work()
    }
}
