import Foundation

/// Ad formats supported by the Video SDK. Both are pause ads (IAB CTV Ad
/// Portfolio "Pause"); they differ in how much of the player they cover.
/// Raw values are the ad server's `AdFormat` enum names.
public enum VideoAdFormat: String, CaseIterable, Codable, Sendable {
    /// Image banner over part of the paused player (IAB `pos = 8`).
    case pauseOverlay = "INSTREAM_IMAGE_PAUSE_OVERLAY"
    /// Image over the whole paused player, with a Resume button (IAB `pos = 7`).
    case pauseFullscreen = "INSTREAM_IMAGE_PAUSE_FULLSCREEN"
}
