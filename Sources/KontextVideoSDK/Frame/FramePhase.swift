/// Where the ad's frame (its web page) is, as `FrameProtocol` moves it: loading, ready off screen, on screen, or
/// gone (terminal). The frame's phase, not the ad's (`AdState`): see `FrameProtocol` for why there are two and how
/// they move together.
///
/// ```
/// loading ──ad.loaded──► loaded ──show──► shown
///    └──────────────────────┴───────────────┴──► ended   (an error, the page's close or skip, the SDK's hide)
/// ```
enum FramePhase: Sendable {
    case loading
    case loaded
    case shown
    case ended
}
