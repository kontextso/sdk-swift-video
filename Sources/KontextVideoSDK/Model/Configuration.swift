import Foundation

extension KontextVideo {
    /// The options a publisher sets when initialising the SDK. They do not change during a run; what the
    /// viewer is and consented to can change later and lives on `KontextVideo.shared` (`user`,
    /// `regulatory`, `variantId`).
    public struct Configuration: Sendable {
        /// Production ad server base URL.
        public static let defaultAdServerURL = URL(string: "https://server.megabrain.co")!

        /// How much the SDK prints to the device console. Each level includes the ones above it.
        public enum LogLevel: Sendable, Comparable {
            /// Silent.
            case none
            /// Only errors.
            case error
            /// Errors and warnings.
            case warning
            /// Errors, warnings and other useful information.
            case info
            /// Detailed information about each step.
            case debug
        }

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
        public let adServerURL: URL

        public init(
            publisherToken: String,
            requestTrackingAuthorization: Bool = false,
            logLevel: LogLevel = .warning,
            adServerURL: URL = Configuration.defaultAdServerURL
        ) {
            self.publisherToken = publisherToken
            self.requestTrackingAuthorization = requestTrackingAuthorization
            self.logLevel = logLevel
            self.adServerURL = adServerURL
        }
    }
}
