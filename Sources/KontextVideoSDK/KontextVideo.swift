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
        /// The server switched the SDK off. Final for this app launch.
        case disabled(reason: String)
        /// `/init` failed twice, usually a bad network at launch. No ads until a later `/init` succeeds:
        /// the SDK tries again at the next video start, 5 minutes after the failure at the earliest.
        case failed
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

    /// What the publisher knows about the viewer. Set it whenever you learn it, for example after login;
    /// the next ads request carries it. Ads already loaded but not shown are discarded on a change.
    public var user: User? {
        didSet { if user != oldValue { targetingChanged("user") } }
    }
    /// Privacy and consent signals. Set what your consent platform gives you; `coppa` can only come from you.
    public var regulatory: Regulatory? {
        didSet { if regulatory != oldValue { targetingChanged("regulatory") } }
    }
    /// Selects which type of ad to render, for A/B testing. Agreed between the publisher and Kontext.
    public var variantId: String? {
        didSet { if variantId != oldValue { targetingChanged("variantId") } }
    }

    public var isInitialized: Bool {
        configuration != nil
    }

    static let initRetryInterval: TimeInterval = 300

    /// When the server asked for the debug log (`reportDebug` in the `/init` response).
    private(set) var reportDebug = false
    private var initTask: Task<Void, Never>?
    private var initFailedAt: Date?

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

    /// The ads for one video. Create it as early as you like, for example for the next episode while
    /// the current one plays, and call `destroy()` on it when the viewer leaves the video.
    public func createVideoAds(for video: Video) -> VideoAds {
        if !isInitialized {
            Logger.warning("createVideoAds(for:) called before initialize(with:); no ads will load until the SDK is initialised")
        }
        return VideoAds(video: video)
    }

    /// Called at the next natural moment after a failed `/init` (a video start): tries again
    /// when the failure is at least `initRetryInterval` old.
    func retryInitIfDue() {
        guard state == .failed, let configuration, let initFailedAt,
              Date().timeIntervalSince(initFailedAt) >= Self.initRetryInterval else { return }
        Logger.info("Retrying /init")
        state = .initializing
        initTask = Task { await runInit(configuration: configuration) }
    }

    /// The spec's rule: when `user`, `regulatory` or `variantId` changes, every loaded ad that was not
    /// shown yet is discarded, and the next request for each format carries the new values.
    private func targetingChanged(_ what: String) {
        Logger.debug("\(what) changed")
        // TODO: discard loaded, unshown ads once VideoAds holds them.
    }

    private func runInit(configuration: Configuration) async {
        let client = APIClient(baseURL: configuration.adServerUrl)
        let request = InitRequest.make(configuration: configuration, installId: Self.installId)
        do {
            switch try await Init.send(request, client: client) {
            case .enabled(let reportDebug):
                self.reportDebug = reportDebug
                initFailedAt = nil
                state = .enabled
                Logger.info("Enabled")
            case .disabled(let reason):
                state = .disabled(reason: reason)
                Logger.warning("Disabled by the server: \(reason)")
            }
        } catch {
            initFailedAt = Date()
            state = .failed
            Logger.error("/init failed, no ads until it succeeds: \(error)")
        }
    }
}
