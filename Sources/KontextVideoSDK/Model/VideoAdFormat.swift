import Foundation

/// Ad formats supported by the Video SDK.
///
/// | Format | Timing | Frequency |
/// |---|---|---|
/// | ``pauseAd`` | Prepared at video start, shown when the user pauses | 1 per video (v1) |
public enum VideoAdFormat: String, CaseIterable, Codable, Sendable {
    case pauseAd
}
