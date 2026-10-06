import Foundation

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
    /// Selects which type of ad to render, for A/B testing. Agreed between the publisher and Kontext.
    public let variantId: String?
    /// Privacy and consent signals.
    public let regulatory: Regulatory?
    /// Whether the SDK shows the App Tracking Transparency dialog itself, before the first ads request.
    /// Off by default, so the app decides when the dialog appears.
    public let requestTrackingAuthorization: Bool
    /// How much the SDK prints to the device console.
    public let logLevel: LogLevel
    /// The ad server base URL, by default the production server.
    /// Override it only for testing against a staging or mock server.
    public let adServerUrl: URL

    public init(
        publisherToken: String,
        user: User? = nil,
        variantId: String? = nil,
        regulatory: Regulatory? = nil,
        requestTrackingAuthorization: Bool = false,
        logLevel: LogLevel = .warning,
        adServerUrl: URL = Constants.defaultAdServerUrl
    ) {
        self.publisherToken = publisherToken
        self.user = user
        self.variantId = variantId
        self.regulatory = regulatory
        self.requestTrackingAuthorization = requestTrackingAuthorization
        self.logLevel = logLevel
        self.adServerUrl = adServerUrl
    }
}
