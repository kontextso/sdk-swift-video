import Foundation

/// Ad formats supported by the Video SDK. Raw values are the ad server's
/// `AdFormat` enum names.
public enum VideoAdFormat: String, CaseIterable, Codable, Sendable {
    /// Image banner over part of the paused player (IAB Pause, `pos = 8`).
    case pause = "INSTREAM_IMAGE_PAUSE"
    /// Full-screen video the SDK presents at a moment the app chooses;
    /// closable once the server's `skip_after_ms` has passed.
    case interstitial = "INSTREAM_VIDEO_INTERSTITIAL"
    /// Image banner while the episode plays, N per video, each with a
    /// server-derived window (IAB Overlay).
    case overlay = "INSTREAM_IMAGE_OVERLAY"
}
