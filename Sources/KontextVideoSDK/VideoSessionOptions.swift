import Foundation

/// Immutable configuration for a ``VideoSession``.
///
/// The SDK automatically manages two IDs the publisher never has to touch:
/// - `installId`: persistent ID generated on first launch (survives restarts)
/// - `sessionId`: ID of the current viewing session, assigned by the server
public struct VideoSessionOptions {
    /// Publisher token issued by Kontext.
    public let publisherToken: String

    /// Publisher's stable user ID.
    public let userId: String

    /// User email, when the publisher has one.
    public let userEmail: String?

    /// Formats this session may show. Defaults to all formats.
    public let enabledFormats: [VideoAdFormat]

    /// Ad server base URL. Override only for development/staging.
    public let adServerURL: URL

    /// Delivered on the main thread for every ad lifecycle event.
    public let onEvent: ((VideoAdEvent) -> Void)?

    public init(
        publisherToken: String,
        userId: String,
        userEmail: String? = nil,
        enabledFormats: [VideoAdFormat] = VideoAdFormat.allCases,
        adServerURL: URL = Constants.defaultAdServerURL,
        onEvent: ((VideoAdEvent) -> Void)? = nil
    ) {
        self.publisherToken = publisherToken
        self.userId = userId
        self.userEmail = userEmail
        self.enabledFormats = enabledFormats
        self.adServerURL = adServerURL
        self.onEvent = onEvent
    }
}
