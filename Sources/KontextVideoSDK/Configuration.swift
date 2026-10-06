/// The options a publisher sets when initialising the SDK.
public struct Configuration: Sendable {
    /// Identifies the publisher. Not a secret.
    public let publisherToken: String

    public init(publisherToken: String) {
        self.publisherToken = publisherToken
    }
}
