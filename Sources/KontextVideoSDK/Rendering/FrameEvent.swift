import Foundation

/// What the frame page told the bridge, already checked and in order. The page only reports
/// moments; the SDK fires every beacon.
enum FrameEvent: Sendable {
    /// The creative is loaded and can be shown (the VAST `loaded` moment).
    case loaded
    /// The viewer clicked the ad. `area` is `creative`, `endCard`, or whatever else the page says.
    case click(url: URL, fallbackUrl: URL?, area: String)
    /// The page needs a URL opened that is not an ad click (`purpose`: `adChoices`, ...). Fires no `click`.
    case open(url: URL, purpose: String)
    /// The page's own end: the viewer's close control (`reason` `close` or `resume`), or the page ending
    /// itself after the video completed with no end card (`complete`).
    case close(reason: String)
    /// The viewer dismissed a video before it completed.
    case skip(playhead: Int)
    /// `start`, `firstQuartile`, `midpoint`, `thirdQuartile`, `pause`, `resume`, `mute`, `unmute`.
    case video(name: String, playhead: Int)
    /// The ad video passed a `progress` entry's offset.
    case progress(offset: Int, playhead: Int)
    /// The video played to the end. The SDK fires `complete` and grants the reward.
    case complete(playhead: Int)
    /// The creative failed to load or play, with the VAST error code.
    case error(code: Int)
    /// The page did not answer in time, or could not be loaded.
    case loadFailed(code: Int)
}
