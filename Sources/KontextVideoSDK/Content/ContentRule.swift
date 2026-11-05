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
///   seeked             count again from the new playhead     count again from the new playhead
///   the scene returns  ignore                                wait contentResumeGrace; still paused: end
///
/// PauseRule            not seen paused yet (shown over       paused
///                      playing content)
///   contentChanged     end                                   end
///   contentEnded       now paused: wait                      wait
///   pause              now paused: wait                      wait
///   play, tick, seeked playing: ignore                       playing: end; paused: wait
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

extension VideoAd {
    /// The tracked content of this ad's `VideoAds`, `nil` once the owner is gone.
    var contentPlayback: ContentPlayback? { owner?.playback }
    /// This ad follows the content: its `VideoAds` tracks a player, alive or gone.
    var isTrackingContent: Bool { contentPlayback?.isTracking == true }
}
