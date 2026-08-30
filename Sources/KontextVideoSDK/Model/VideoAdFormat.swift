import Foundation

/// Ad formats supported by the Video SDK. Raw values are the ad server's
/// `AdFormat` enum names.
public enum VideoAdFormat: String, CaseIterable, Codable, Sendable {
    /// Image banner over part of the paused player (IAB Pause, `pos = 8`).
    case pauseOverlay = "INSTREAM_IMAGE_PAUSE_OVERLAY"
    /// Image over the whole paused player, with a Resume button (IAB Pause, `pos = 7`).
    case pauseFullscreen = "INSTREAM_IMAGE_PAUSE_FULLSCREEN"
    /// Full-screen video between two episodes, hosted as a page in the
    /// app's feed; swiped away once the server's `skip_after_ms` has passed.
    case swipe = "INSTREAM_VIDEO_SWIPE"
}
