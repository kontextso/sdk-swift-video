import Foundation

/// How an ad on screen follows the app's content player: one rule per format, chosen once per ad.
///
/// Why: with a player tracked by `VideoAds.track(_:)`, an overlay and a pause ad live by the content, in
/// opposite ways, and a linear ad does not care. Each format's way lives in its own type, so `VideoAd`
/// never asks "which format am I?" about the content.
///
/// ```
/// OverlayRule    lives while the content plays: a pause, the end, another item ends it (.interrupted);
///                its duration counts seconds of video; it cannot be shown over paused content
/// PauseRule      lives while the content is paused: content playing again ends it (.interrupted)
/// NoContentRule  a linear ad: full screen over the content, which it never follows
/// ```
///
/// How: `VideoAd` asks its rule at four moments:
/// 1. before `show`'s checks: the ad on screen ends if its content stopped (`endIfContentStopped`), and the
///    new ad may refuse to go up (`refusesShow`); an inline ad is also checked against its episode
///    (`checksEpisode`);
/// 2. once on screen: the rule learns the ad's clock (`started(clock:)`), whose duration it chose
///    (`wallClockDuration`);
/// 3. on every change of the tracked player, and on its ticks, through the owner (`contentDidChange`);
/// 4. at the end: its own timers stop (`cancel`).
/// A rule ends its ad only through `VideoAd.end(_:)`, the one terminal path. Tracking can begin after
/// `show` (a player made late): a rule reads `isTracking` each time instead of deciding once.
///
/// What each rule does with a change of the tracked player, by the state it is in (an ad on screen over a
/// tracked player; "end" is `end(.interrupted)` unless it says otherwise):
///
/// ```
/// OverlayRule          playing                               frozen (paused while its scene was away)
///   contentChanged     end                                   end
///   contentEnded       end                                   end
///   pause              end; freeze if the scene is inactive  stay frozen
///   play               ignore                                go on (unfreeze)
///   tick               count its seconds of video; end       stay frozen while paused, go on once playing
///                      (.completed) once they reach duration
///   jumped (a seek)    count again from the new playhead     count again from the new playhead
///   the scene returns  ignore                                wait contentResumeGrace; still paused: end
///
/// PauseRule            not seen paused yet (shown over       paused
///                      playing content)
///   contentChanged     end                                   end
///   contentEnded       now paused: wait                      wait
///   pause              now paused: wait                      wait
///   play, tick, jumped playing: ignore                       playing: end; paused: wait
///
/// NoContentRule        ignore every change
/// ```
///
/// Without a tracked player both overlay and pause ads run on active time and the app's calls alone.
/// `.interrupted` has other causes too (the view leaving the window, too little room), so the app reads
/// its player's state rather than the reason.
@MainActor
protocol ContentRule: AnyObject {
    /// `show` must refuse the ad now (`contentPaused`): an overlay over paused content. Reads the app's
    /// player.
    var refusesShow: Bool { get }
    /// `show` refuses an ad whose episode no longer plays in the tracked player: an ad requested for an
    /// episode is counted for it. Not a linear ad, which is not tied to what plays under it.
    var checksEpisode: Bool { get }
    /// The duration the ad's active-time clock ends it at, `nil` for none: an overlay's `duration` when it
    /// does not follow a player (one that does counts seconds of video instead). Read once, at show.
    var wallClockDuration: TimeInterval? { get }
    /// The ad is on screen with its clock running: the rule starts following the content from here.
    func started(clock: ActiveTimeClock)
    /// The tracked player changed, or a tick came.
    func contentDidChange(_ change: ContentPlayback.Change)
    /// The ad ends when its content no longer fits it: before another ad's `show`, and after its own view
    /// was attached, for a change no callback reported while that ran.
    func endIfContentStopped()
    /// The ad is ending: the rule's own timers stop.
    func cancel()
}

/// The rule for `ad`'s format. A function, not a static on `ContentRule`: Swift cannot call a static on a
/// protocol's own type.
@MainActor
func makeContentRule(for ad: VideoAd) -> any ContentRule {
    switch ad.format {
    case .overlay: OverlayRule(ad: ad)
    case .pause: PauseRule(ad: ad)
    case .linear: NoContentRule()
    }
}

/// An overlay lives only while the content plays: a pause, the end of the content, another item, another
/// player or a player that is gone ends it as `.interrupted`; its `duration` counts seconds of video; and it
/// cannot be shown over paused content. A pause while the overlay's scene is not active (the app in the
/// background, where iOS pauses the player itself and apps often pause their own) does not end it: the
/// overlay freezes, as its clock does, and once the scene is active again the content has
/// `contentResumeGrace` to play again before that pause ends it as any other.
@MainActor
final class OverlayRule: ContentRule {
    unowned let ad: VideoAd

    /// How long, once its scene is active again, an overlay frozen by a pause in the background waits for
    /// the app to play the content again before the pause ends it. Tests shorten it.
    static var contentResumeGrace: TimeInterval = 1

    /// The overlay's `duration` in seconds of video, once on screen over a tracked player.
    private(set) var contentProgress: ContentProgress?
    /// A pause came while the scene was not active: the overlay is frozen, not ended.
    private(set) var contentPausedWhileInactive = false
    /// That overlay's check after its scene came back.
    private(set) var contentRecheck: Task<Void, Never>?

    init(ad: VideoAd) {
        self.ad = ad
    }

    /// This overlay follows the content: its `VideoAds` tracks a player, alive or gone.
    var followsContent: Bool { ad.owner?.playback.isTracking == true }

    var refusesShow: Bool {
        guard followsContent, ad.owner?.playback.isPlaying == false else { return false }
        Logger.warning("ad \(ad.id.prefix(8)): cannot show the overlay, the content is paused")
        return true
    }

    var checksEpisode: Bool { true }

    var wallClockDuration: TimeInterval? { followsContent ? nil : ad.duration }

    /// The overlay is on screen: its `duration`, if any, counts from the playhead now, and starts again from
    /// the playhead whenever its scene comes back: video played while it could not be seen counts nothing.
    /// A pause while the scene was away is checked again once it is back.
    func started(clock: ActiveTimeClock) {
        guard followsContent, let owner = ad.owner else { return }
        if let duration = ad.duration { contentProgress = ContentProgress(duration: duration, at: owner.playback.playhead) }
        clock.onActivate = { [weak self] in
            guard let self, let playback = ad.owner?.playback else { return }
            contentProgress?.resync(to: playback.playhead)
            if contentPausedWhileInactive { recheckContentAfterGrace() }
        }
    }

    /// An overlay cares from the moment `show` reserved it: a pause while its view is being attached ends it
    /// before any impression.
    func contentDidChange(_ change: ContentPlayback.Change) {
        guard followsContent, ad.wasShown, !ad.hasEnded, let playback = ad.owner?.playback else { return }
        switch change {
        case .contentChanged, .contentEnded:
            Logger.info("ad \(ad.id.prefix(8)): the content ended or changed; the overlay ends")
            ad.end(.interrupted)
            return
        case .playback(isPlaying: false):
            if freezesOnPause() { return }
            Logger.info("ad \(ad.id.prefix(8)): the content paused; the overlay ends")
            ad.end(.interrupted)
            return
        case .jumped:
            contentProgress?.resync(to: playback.playhead)
            return
        case .playback, .tick:
            break
        }
        guard playback.isPlaying else {
            if freezesOnPause() { return }
            Logger.info("ad \(ad.id.prefix(8)): the content paused or its player is gone; the overlay ends")
            ad.end(.interrupted)
            return
        }
        if contentPausedWhileInactive {
            // The content plays again: the frozen overlay goes on where it stopped.
            Logger.info("ad \(ad.id.prefix(8)): the content plays again; the overlay goes on")
            contentPausedWhileInactive = false
            contentRecheck?.cancel()
            contentRecheck = nil
        }
        guard change == .tick, let contentProgress, !ad.hasEnded else { return }
        // Seconds of video while the overlay is seen: not while its scene is inactive or it is out of sight.
        if contentProgress.advance(to: playback.playhead, counting: ad.clock?.isCounting == true, rate: playback.rate) {
            Logger.debug("ad \(ad.id.prefix(8)): overlay duration of \(contentProgress.duration) s of video elapsed")
            ad.state.markCompleted()
            ad.end(.completed)
        }
    }

    /// An overlay shown right after `player.play()` finds the screen free of a pause ad, and one whose own
    /// view was attached over content that paused meanwhile ends.
    func endIfContentStopped() {
        guard ad.wasShown, !ad.hasEnded, followsContent, ad.owner?.playback.isPlaying == false else { return }
        Logger.info("ad \(ad.id.prefix(8)): the content paused; the overlay ends")
        ad.end(.interrupted)
    }

    func cancel() {
        contentRecheck?.cancel()
        contentRecheck = nil
    }

    /// A pause while the overlay's scene is not active freezes the overlay instead of ending it: leaving the
    /// app pauses an `AVPlayer` and, often, the app's own player, and the viewer coming back expects the
    /// overlay still there. It stays frozen, whatever the content reports, until the content plays again or
    /// the check after the scene's return. Returns whether the overlay stays. Before its clock exists (the
    /// view still being attached) a pause ends it as always.
    private func freezesOnPause() -> Bool {
        if ad.clock?.isSceneActive == false, !contentPausedWhileInactive {
            Logger.info("ad \(ad.id.prefix(8)): the content paused while the scene is not active; the overlay freezes")
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
            guard followsContent, !ad.hasEnded, contentPausedWhileInactive, ad.clock?.isSceneActive == true,
                  let playback = ad.owner?.playback else { return }
            contentPausedWhileInactive = false
            if playback.isPlaying {
                Logger.info("ad \(ad.id.prefix(8)): the content plays again; the overlay goes on")
                return
            }
            Logger.info("ad \(ad.id.prefix(8)): the content is still paused after the scene came back; the overlay ends")
            ad.end(.interrupted)
        }
    }
}

/// A pause ad lives only while the content is paused: once the content plays again, resumed from anywhere
/// (the lock screen, Control Center, a headset, PiP, the app's own code), it ends as `.interrupted`;
/// `.resumed` stays the viewer's Resume on the ad. It ends at once when its episode is gone from the
/// player: another `VideoAds` took the player (the next page of a feed sharing one player) or it plays
/// another item. Shown on, it would hold the app's one slot over content it is not for.
@MainActor
final class PauseRule: ContentRule {
    unowned let ad: VideoAd

    /// The content was seen paused since `show`: from then on, content seen playing ends the ad.
    private(set) var contentPausedSinceShow = false

    init(ad: VideoAd) {
        self.ad = ad
    }

    /// This pause ad follows the content: its `VideoAds` tracks a player, alive or gone.
    var followsContent: Bool { ad.owner?.playback.isTracking == true }

    var refusesShow: Bool { false }

    var checksEpisode: Bool { true }

    /// A pause ad has no `duration`: nothing ends it on time.
    var wallClockDuration: TimeInterval? { nil }

    /// A pause ad is on screen: from here on, content seen playing after it was seen paused ends it. Content
    /// that already played at `show` must pause first: a rate change of playing content is no resume.
    func started(clock: ActiveTimeClock) {
        guard followsContent, let playback = ad.owner?.playback else { return }
        contentPausedSinceShow = !playback.isPlaying
    }

    func contentDidChange(_ change: ContentPlayback.Change) {
        guard followsContent, ad.state.wasOnScreen, !ad.hasEnded, let playback = ad.owner?.playback else { return }
        let playing: Bool
        switch change {
        case .contentChanged:
            Logger.info("ad \(ad.id.prefix(8)): the content changed or another VideoAds took the player; the pause ad ends")
            return ad.end(.interrupted)
        case .playback(isPlaying: let value?): playing = value
        case .contentEnded: playing = false
        case .playback(isPlaying: nil), .jumped, .tick: playing = playback.isPlaying
        }
        endIfContentResumed(playing: playing)
    }

    /// A pause ad shown right before `player.play()` ends at the next ad's `show`, which finds the screen free.
    func endIfContentStopped() {
        guard followsContent, ad.state.wasOnScreen, !ad.hasEnded, let playback = ad.owner?.playback else { return }
        endIfContentResumed(playing: playback.isPlaying)
    }

    func cancel() {}

    private func endIfContentResumed(playing: Bool) {
        guard playing else {
            contentPausedSinceShow = true
            return
        }
        guard contentPausedSinceShow else { return }
        Logger.info("ad \(ad.id.prefix(8)): the content plays again; the pause ad ends")
        ad.end(.interrupted)
    }
}

/// A linear ad covers the screen over the content and never follows it: no player change ends it, no
/// episode check refuses it, nothing about the content is counted.
@MainActor
final class NoContentRule: ContentRule {
    var refusesShow: Bool { false }
    var checksEpisode: Bool { false }
    var wallClockDuration: TimeInterval? { nil }
    func started(clock: ActiveTimeClock) {}
    func contentDidChange(_ change: ContentPlayback.Change) {}
    func endIfContentStopped() {}
    func cancel() {}
}

extension VideoAd {
    /// The app code a `show` runs before its checks: an ad on screen over content that stopped ends (its
    /// `didEnd`), and the player is read. Every check after it sees what that code left. Returns whether the
    /// content refuses this ad: an overlay over paused content.
    func runAppCodeBeforeShow() -> Bool {
        // An ad already shown leaves the ad on screen alone; `show` throws `alreadyShown` right after.
        if !wasShown { KontextVideo.shared.adOnScreen?.contentRule.endIfContentStopped() }
        return contentRule.refusesShow
    }
}
