/// The options a publisher sets when initialising the SDK.
public struct Configuration: Sendable {
    /// Identifies the publisher. Not a secret.
    ///
    /// Publishers typically have two kinds of token:
    /// - a developer token for testing, `{publisher}-dev`
    /// - a production token, `{publisher}-{unique string}`
    public let publisherToken: String
    /// What the publisher knows about the viewer.
    public let user: User?

    public init(
        publisherToken: String,
        user: User? = nil
    ) {
        self.publisherToken = publisherToken
        self.user = user
    }
}
