import Foundation

/// Ad formats supported by the Video SDK.
///
/// | Format | Timing | Frequency |
/// |---|---|---|
/// | ``overlay`` | All requested at the start of the video, shown at server-scheduled times | N per video |
/// | ``pauseAd`` | Prepared at video start, shown when the user pauses | 1 per video (v1) |
/// | ``swipeBanner`` | Prepared before the swipe can happen; app triggers it | max 1 per video |
public enum VideoAdFormat: String, CaseIterable, Codable, Sendable {
    case overlay
    case pauseAd
    case swipeBanner
}
