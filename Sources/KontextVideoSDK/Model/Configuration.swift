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

        /// Identifies the publisher. Not a secret. Required and non-empty: an empty token stops a debug
        /// build at `initialize(with:)`, and the server refuses its requests.
        ///
        /// Publishers typically have two kinds of token:
        /// - a developer token for testing, `{publisher}-dev`
        /// - a production token, `{publisher}-{unique string}`
        public let publisherToken: String
        /// Whether the SDK shows the App Tracking Transparency dialog itself, before the first ads request,
        /// when the viewer has not answered yet. Needs `NSUserTrackingUsageDescription` in the app's
        /// Info.plist. Off by default, so the app decides when the dialog appears; off only stops the SDK
        /// asking, it still reads the status the app's own dialog produced and sends the IDFA when allowed.
        public let requestTrackingAuthorization: Bool
        /// How much the SDK prints to the device console. Console only: `.none` does not stop the debug
        /// reporting the server can switch on.
        public let logLevel: LogLevel
        /// The ad server base URL, by default the production server: absolute, `https` (or `http` for a
        /// local mock), without a path the SDK adds itself (`/v2/...`). Override it only for testing against
        /// a staging or mock server; a URL without a scheme and host stops a debug build.
        public let adServerURL: URL

        /// Only `publisherToken` is required.
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

        /// What is wrong with the options, one phrase each; empty when they are usable.
        var problems: [String] {
            var problems: [String] = []
            if publisherToken.isEmpty { problems.append("publisherToken is empty") }
            if adServerURL.scheme == nil || (adServerURL.host ?? "").isEmpty { problems.append("adServerURL \(adServerURL) is not absolute") }
            return problems
        }
    }
}
