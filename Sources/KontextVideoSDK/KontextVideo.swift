import Foundation
import KontextKit

/// Entry point of the Kontext Video SDK.
@MainActor
public final class KontextVideo {
    /// Whether the SDK may request ads.
    public enum State: Sendable, Equatable {
        case notInitialized
        /// `/init` is in flight. Ads requests wait for it.
        case initializing
        case enabled
        /// The server switched the SDK off, or `/init` failed. No ads until the next app launch.
        case disabled(reason: String)
    }

    public static let shared = KontextVideo()

    public nonisolated static let version = SDKInfo.current.version

    /// Identifies this installation of the app. Created on first use and kept until the app is uninstalled.
    public static var installId: String {
        InstallIdProvider.getOrCreate()
    }

    /// The configuration the SDK was initialised with, or `nil` before `initialize(with:)`.
    public private(set) var configuration: Configuration?
    public private(set) var state: State = .notInitialized

    public var isInitialized: Bool {
        configuration != nil
    }

    private static let sessionIdKey = "so.kontext.video.sessionId"
    private var initTask: Task<Void, Never>?

    private init() {}

    /// Starts the SDK: stores the configuration and calls `/init` in the background.
    /// Call it once, at app launch; later calls are ignored. `completion` runs on the main thread
    /// once `/init` has answered or failed.
    public func initialize(with configuration: Configuration, completion: ((State) -> Void)? = nil) {
        guard !isInitialized else {
            Logger.warning("initialize(with:) was already called; this call is ignored")
            return
        }
        self.configuration = configuration
        Logger.level = configuration.logLevel
        Logger.debug("Initialising, SDK version \(Self.version)")
        state = .initializing
        initTask = Task {
            await runInit(configuration: configuration)
            completion?(state)
        }
    }

    private func runInit(configuration: Configuration) async {
        let client = APIClient(baseURL: configuration.adServerUrl)
        let request = InitRequest.make(configuration: configuration, installId: Self.installId, sessionId: storedSessionId)
        do {
            switch try await Init.send(request, client: client) {
            case .enabled(let sessionId, _, _):
                storedSessionId = sessionId
                state = .enabled
                Logger.info("Enabled, session \(sessionId)")
            case .disabled(let reason):
                state = .disabled(reason: reason)
                Logger.warning("Disabled by the server: \(reason)")
            }
        } catch {
            state = .disabled(reason: "/init failed: \(error)")
            Logger.error("/init failed, no ads this launch: \(error)")
        }
    }

    /// The session id from the last `/init` or ads response. The server decides whether it is still valid.
    private var storedSessionId: String? {
        get { UserDefaults.standard.string(forKey: Self.sessionIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sessionIdKey) }
    }
}
