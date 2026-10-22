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

        /// When a format's loader asks the server for the next ad by itself.
        public enum RefetchPolicy: Sendable, Equatable {
            /// Never: the next `ads.format(_:)` or `load()` fetches when the SDK holds nothing.
            case never
            /// After an ad of the format ended (`didEnd`): the loader fetches the next one with the options
            /// declared at `VideoAds` creation, so the next `ads.format(_:)` / `load()` renders at once. One request per
            /// ended ad, never a loop.
            case afterEnd
        }

        /// What a format does unless told otherwise. One entry per format; v2 may add per-request overrides.
        public struct FormatDefaults: Sendable, Equatable {
            public var refetch: RefetchPolicy

            public init(refetch: RefetchPolicy) {
                self.refetch = refetch
            }
        }

        /// The defaults of every format: overlay and pause ads recur within a video, so they refetch after
        /// each ended ad; a linear ad's `timing` names one moment, so it does not.
        public static let defaultFormats: [AdFormat: FormatDefaults] = [
            .overlay: FormatDefaults(refetch: .afterEnd),
            .pause: FormatDefaults(refetch: .afterEnd),
            .linear: FormatDefaults(refetch: .never),
        ]

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
        /// Per-format defaults; every format has an entry (`defaultFormats`, with the given ones on top).
        public let formats: [AdFormat: FormatDefaults]

        /// `formats` overrides the defaults per format: `[.linear: .init(refetch: .afterEnd)]` changes linear
        /// and leaves overlay and pause as they are.
        public init(
            publisherToken: String,
            requestTrackingAuthorization: Bool = false,
            logLevel: LogLevel = .warning,
            adServerURL: URL = Configuration.defaultAdServerURL,
            formats: [AdFormat: FormatDefaults] = [:]
        ) {
            self.publisherToken = publisherToken
            self.requestTrackingAuthorization = requestTrackingAuthorization
            self.logLevel = logLevel
            self.adServerURL = adServerURL
            self.formats = Configuration.defaultFormats.merging(formats) { _, given in given }
        }
    }
}
