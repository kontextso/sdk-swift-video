import Foundation

/// Static entry point of the Kontext Video SDK.
///
/// ```swift
/// let session = KontextVideo.createSession(VideoSessionOptions(
///     publisherToken: "pub-xxxx",
///     userId: "user-123"
/// ))
/// ```
@MainActor
public enum KontextVideo {
    /// Creates a new video session. One session per app user; it survives
    /// across episodes and videos.
    public static func createSession(_ options: VideoSessionOptions) -> VideoSession {
        VideoSession(options: options)
    }
}
