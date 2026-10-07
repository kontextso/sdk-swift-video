import Foundation

/// The options a publisher sets when initialising the SDK. They do not change during a run; what the
/// viewer is and consented to can change later and lives on `KontextVideo.shared` (`user`,
/// `regulatory`, `variantId`).
public struct Configuration: Sendable {
    /// Identifies the publisher. Not a secret.
    ///
    /// Publishers typically have two kinds of token:
    /// - a developer token for testing, `{publisher}-dev`
    /// - a production token, `{publisher}-{unique string}`
    public let publisherToken: String
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
        requestTrackingAuthorization: Bool = false,
        logLevel: LogLevel = .warning,
        adServerUrl: URL = Constants.defaultAdServerUrl
    ) {
        self.publisherToken = publisherToken
        self.requestTrackingAuthorization = requestTrackingAuthorization
        self.logLevel = logLevel
        self.adServerUrl = adServerUrl
    }
}
