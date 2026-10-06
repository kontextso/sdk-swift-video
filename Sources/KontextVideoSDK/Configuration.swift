/// The options a publisher sets when initialising the SDK.
public struct Configuration: Sendable {
    /// Identifies the publisher. Not a secret.
    ///
    /// Publishers typically have two kinds of token:
    /// - a developer token for testing, `{publisher}-dev`
    /// - a production token, `{publisher}-{unique string}`
    public let publisherToken: String

    public init(publisherToken: String) {
        self.publisherToken = publisherToken
    }
}
