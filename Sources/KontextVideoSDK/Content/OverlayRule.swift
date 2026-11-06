import Foundation

/// An overlay lives only while the content plays: a pause, the end of the content, another item, another
/// player or a player that is gone ends it as `.interrupted`; its `duration` counts seconds of video; and it
/// cannot be shown over paused content. A pause while the overlay's scene is not active (the app in the
/// background, where iOS pauses the player itself and apps often pause their own) does not end it: the
/// overlay freezes, as its clock does, and once the scene is active again the content has
/// `contentResumeGrace` to play again before that pause ends it as any other. A pause under the in-app browser
/// of the overlay's own click is the same: the viewer is away, and comes back at "Done".
@MainActor
final class OverlayRule: ContentRule {
    unowned let ad: VideoAd

    /// How long, once its scene is active again, an overlay frozen by a pause in the background waits for
    /// the app to play the content again before the pause ends it. Tests shorten it.
    static var contentResumeGrace: TimeInterval = 1

    /// The overlay's `duration` in seconds of video, once on screen over a tracked player.
    private(set) var contentClock: ContentTimeClock?
    /// A pause came while the viewer was away (`isViewerAway`): the overlay is frozen, not ended.
    private(set) var wasContentPausedWhileInactive = false
    /// That overlay's check after its scene came back.
    private(set) var contentRecheck: Task<Void, Never>?

    init(ad: VideoAd) {
        self.ad = ad
    }

    var refusesShow: Bool {
        guard ad.isTrackingContent, ad.contentPlayback?.isPlaying == false else { return false }
        Logger.warning("ad \(ad.id.prefix(8)): cannot show the overlay, the content is paused")
        return true
    }

    var checksEpisode: Bool { true }

    var wallClockDuration: TimeInterval? { ad.isTrackingContent ? nil : ad.duration }

    /// The overlay is on screen: its `duration`, if any, counts from the playhead now, and starts again from
    /// the playhead whenever counting resumes (its scene came back, or it came back into sight): video played while
    /// it could not be seen counts nothing.
    /// A pause while the scene was away is checked again once it is back. Shown with no player tracked, it says
    /// so: its duration then is time on screen, which an app that calls `track(_:)` after `show` may not expect.
    func started(onScreenClock clock: OnScreenTimeClock) {
        // Installed whatever is tracked now: a player tracked after `show` can still freeze the overlay with a pause
        // in the background, and only this check ends that freeze once the scene is back.
        clock.onResume = { [weak self] in
            guard let self, ad.isTrackingContent, let playback = ad.contentPlayback else { return }
            contentClock?.resync(to: playback.playhead)
            if wasContentPausedWhileInactive { recheckContentAfterGrace() }
        }
        guard ad.isTrackingContent, let playback = ad.contentPlayback else {
            Logger.warning("overlay \(ad.id.prefix(8)) shown before track(): its duration counts on-screen time, not video time")
            return
        }
        if let duration = ad.duration { contentClock = ContentTimeClock(duration: duration, at: playback.playhead) }
    }

    /// An overlay cares from the moment `show` reserved it: a pause while its view is being attached ends it
    /// before any impression.
    func contentDidChange(_ change: ContentPlayback.Change) {
        guard ad.isTrackingContent, ad.wasShown, !ad.hasEnded, let playback = ad.contentPlayback else { return }
        switch change {
        case .contentChanged, .contentEnded:
            Logger.info("ad \(ad.id.prefix(8)): the content ended or changed; the overlay ends")
            ad.end(.interrupted)
            return
        case .playingChanged(isPlaying: false):
            if freezesOnPause() { return }
            Logger.info("ad \(ad.id.prefix(8)): the content paused; the overlay ends")
            ad.end(.interrupted)
            return
        case .seeked:
            contentClock?.resync(to: playback.playhead)
            return
        case .playingChanged, .tick:
            break
        }
        guard playback.isPlaying else {
            if freezesOnPause() { return }
            Logger.info("ad \(ad.id.prefix(8)): the content paused or its player is gone; the overlay ends")
            ad.end(.interrupted)
            return
        }
        if wasContentPausedWhileInactive {
            // The content plays again: the frozen overlay goes on where it stopped.
            Logger.info("ad \(ad.id.prefix(8)): the content plays again; the overlay goes on")
            wasContentPausedWhileInactive = false
            contentRecheck?.cancel()
            contentRecheck = nil
        }
        guard change == .tick, let contentClock, !ad.hasEnded else { return }
        // Seconds of video while the overlay is seen: not while its scene is inactive or it is out of sight.
        if contentClock.advance(to: playback.playhead, isCounting: ad.onScreenClock?.isCounting == true, rate: playback.rate) {
            Logger.debug("ad \(ad.id.prefix(8)): overlay duration of \(contentClock.duration) s of video elapsed")
            ad.state.markCompleted()
            ad.end(.completed)
        }
    }

    /// An overlay shown right after `player.play()` finds the slot free of a pause ad, and one whose own
    /// view was attached over content that paused meanwhile ends.
    func endIfContentStopped() {
        guard ad.wasShown, !ad.hasEnded, ad.isTrackingContent, ad.contentPlayback?.isPlaying == false else { return }
        Logger.info("ad \(ad.id.prefix(8)): the content paused; the overlay ends")
        ad.end(.interrupted)
    }

    func cancel() {
        contentRecheck?.cancel()
        contentRecheck = nil
    }

    /// A pause while the viewer is away (`isViewerAway`) freezes the overlay instead of ending it: leaving the
    /// app pauses an `AVPlayer` and, often, the app's own player, and the viewer coming back expects the
    /// overlay still there. It stays frozen, whatever the content reports, until the content plays again or
    /// the check after the viewer's return. Returns whether the overlay stays. Before its clock exists (the
    /// view still being attached) a pause ends it as always.
    private func freezesOnPause() -> Bool {
        if isViewerAway, !wasContentPausedWhileInactive {
            Logger.info("ad \(ad.id.prefix(8)): the content paused while the viewer is away (the scene not active, or the click's browser up); the overlay freezes")
            wasContentPausedWhileInactive = true
        }
        return wasContentPausedWhileInactive
    }

    /// The viewer is not in front of the player: the overlay's scene is not active, or the in-app browser of its
    /// own click covers it. `false` before the overlay's clock exists.
    private var isViewerAway: Bool {
        guard let clock = ad.onScreenClock else { return false }
        return !clock.isSceneActive || ad.inAppBrowser.isOpen
    }

    /// The viewer is back over an overlay frozen by a pause (the scene active, the browser closed): the app may be
    /// about to play the content again, so the pause is read once more after `contentResumeGrace`. Still paused,
    /// with the viewer still there, the overlay ends as on any pause; a viewer away again waits for the next return.
    private func recheckContentAfterGrace() {
        contentRecheck?.cancel()
        contentRecheck = Task { [weak self] in
            try? await Task.sleep(seconds: Self.contentResumeGrace)
            guard let self, !Task.isCancelled else { return }
            contentRecheck = nil
            guard ad.isTrackingContent, !ad.hasEnded, wasContentPausedWhileInactive, ad.onScreenClock?.isSceneActive == true,
                  !ad.inAppBrowser.isOpen, let playback = ad.contentPlayback else { return }
            wasContentPausedWhileInactive = false
            if playback.isPlaying {
                Logger.info("ad \(ad.id.prefix(8)): the content plays again; the overlay goes on")
                return
            }
            Logger.info("ad \(ad.id.prefix(8)): the content is still paused after the scene came back; the overlay ends")
            ad.end(.interrupted)
        }
    }
}
