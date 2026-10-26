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
    /// The page's own end: the viewer's close control, or the page ending itself.
    case close(reason: CloseReason)
    /// The viewer dismissed a video before it completed.
    case skip(playhead: Int)
    /// A moment of the ad video; the SDK fires the beacon of the same name.
    case video(VideoEvent, playhead: Int)
    /// The ad video passed a `progress` entry's offset.
    case progress(offset: Int, playhead: Int)
    /// The video played to the end. The SDK fires `complete`.
    case complete(playhead: Int)
    /// The creative failed to load or play, with the VAST error code: the page's own (`ad.error`), or the
    /// bridge's when it decided itself (no `ad.loaded` in time, the page could not be loaded, the web
    /// process died: 400 for a video, 500 otherwise, 405 after show).
    case error(code: Int)

    /// The video moments a page reports (`video.<name>`), named as their VAST beacons. `skip`, `progress`
    /// and `complete` carry more and are events of their own.
    enum VideoEvent: String, Sendable, CaseIterable {
        case start, firstQuartile, midpoint, thirdQuartile, pause, resume, mute, unmute
    }

    /// Why the page ended itself. A reason the SDK does not know reads as `close`.
    enum CloseReason: String, Sendable {
        /// The viewer tapped the close control (✕).
        case close
        /// The viewer tapped Resume on a full-screen pause ad.
        case resume
        /// The video completed and there is no end card: nobody closed anything.
        case complete
    }
}
