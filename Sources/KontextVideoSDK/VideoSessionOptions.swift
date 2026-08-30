import Foundation

/// Immutable configuration for a ``VideoSession``.
///
/// The viewing-session ID is assigned by the server and managed by the SDK;
/// the publisher never has to touch it.
public struct VideoSessionOptions {
    /// Publisher token issued by Kontext.
    public let publisherToken: String

    /// Publisher's stable user ID.
    public let userId: String

    /// User email, when the publisher has one.
    public let userEmail: String?

    /// Ad server base URL. Override for development/staging — e.g. the
    /// mock server at `http://localhost:5175`.
    public let adServerURL: URL

    /// Delivered on the main thread for every ad lifecycle event.
    public let onEvent: ((VideoAdEvent) -> Void)?

    public init(
        publisherToken: String,
        userId: String,
        userEmail: String? = nil,
        adServerURL: URL = Constants.defaultAdServerURL,
        onEvent: ((VideoAdEvent) -> Void)? = nil
    ) {
        self.publisherToken = publisherToken
        self.userId = userId
        self.userEmail = userEmail
        self.adServerURL = adServerURL
        self.onEvent = onEvent
    }
}
