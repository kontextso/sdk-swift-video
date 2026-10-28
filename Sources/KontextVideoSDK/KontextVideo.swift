import Foundation
import KontextKit

/// Entry point of the Kontext Video SDK.
@MainActor
public final class KontextVideo {
    /// Whether the SDK may request ads.
    public enum State: Sendable, Equatable {
        case notInitialized
        /// `/config` is in flight. Ads requests wait for it.
        case initializing
        case enabled
        /// The server switched the SDK off. Final for this app launch.
        case disabled(reason: String)
        /// `/config` failed twice, usually a bad network at launch. No ads until a later `/config` succeeds:
        /// every ads request retries it first, whenever it comes.
        case failed
    }

    /// The one instance. Every public call goes through it, as `GADMobileAds.sharedInstance()` or `ALSdk.shared()`.
    public static let shared = KontextVideo()

    /// The SDK's version, the same string it sends with every request. For your logs and crash reports.
    public nonisolated static let version = SDKInfo.version

    /// Identifies this installation of the app, sent with every request. Created on first use and kept until
    /// the app is uninstalled. Internal: an app has no use for it, and must not reuse it as its own user id.
    static var installId: String {
        InstallIdProvider.getOrCreate()
    }

    /// The configuration the SDK was initialised with, or `nil` before `initialize(with:)`.
    private(set) var configuration: Configuration?
    /// Where `/config` got to. Internal: the app gets it from `initialize(with:)`'s completion or `async` form.
    private(set) var state: State = .notInitialized

    /// What the publisher knows about the viewer. Set it whenever you learn it, for example after login;
    /// the next ads request carries it. Ads already loaded or fetched keep the targeting they were requested with.
    public var user: User?
    /// Privacy and consent signals. Set what your consent platform gives you; `coppa` can only come from you.
    /// The next ads request carries them; ads already loaded stay.
    public var regulatory: Regulatory?
    /// Selects which type of ad to render, for A/B testing. Agreed between the publisher and Kontext.
    public var variantId: String?

    /// Whether `initialize(with:)` was called; not whether `/config` succeeded, which is `state`.
    var isInitialized: Bool {
        configuration != nil
    }

    /// The ad on screen, from any `VideoAds`: at most one in the whole app. Set at `show`, cleared at
    /// `didEnd`; holding it here also retains the ad until then, whatever the app does with its reference.
    var adOnScreen: VideoAd?

    /// The server's reason while the SDK is switched off, else `nil`.
    var disabledReason: String? {
        if case .disabled(let reason) = state { return reason }
        return nil
    }

    /// When the server asked for the debug log (`reportDebug` in the `/config` response).
    private(set) var reportDebug = false
    private var initTask: Task<Void, Never>?

    private init() {}

    /// Starts the SDK: stores the configuration and calls `/config` in the background.
    /// Call it once, at app launch; later calls are ignored. `completion` runs on the main thread
    /// once `/config` has answered or failed.
    public func initialize(with configuration: Configuration, completion: ((State) -> Void)? = nil) {
        guard !isInitialized else {
            Logger.warning("initialize(with:) was already called; this call is ignored")
            return
        }
        self.configuration = configuration
        Logger.level = configuration.logLevel
        Logger.debug("Initialising, SDK version \(Self.version)")
        state = .initializing
        // The browser user agent every ads request carries: evaluated in a WebView once per process and
        // cached by KontextKit. Started now so the first request does not wait for it.
        Task { _ = await NetworkInfoProvider.collect() }
        initTask = Task {
            await fetchConfig(configuration: configuration)
            // Cancelled by `resetForTesting()`: the state is no longer this call's to report.
            guard !Task.isCancelled else { return }
            completion?(state)
        }
    }

    /// The same, for `async` code: returns the state once `/config` has answered or failed, as AdMob's
    /// `await MobileAds.shared.start()`. Swift picks this overload in an `async` context and the
    /// fire-and-forget one elsewhere.
    public func initialize(with configuration: Configuration) async -> State {
        initialize(with: configuration, completion: nil)
        await initTask?.value
        return state
    }

    /// Whether ads may be requested now: waits while `/config` is in flight, retries it first after a
    /// failure, and answers `false` when the SDK is off.
    func waitUntilEnabled() async -> Bool {
        if state == .failed {
            retryConfig()
        }
        if state == .initializing {
            await initTask?.value
        }
        return state == .enabled
    }

    /// An ads response said `enabled: false`: the same kill switch as `/config`.
    func disable(reason: String) {
        guard state != .disabled(reason: reason) else { return }
        state = .disabled(reason: reason)
        Logger.warning("Disabled by the server: \(reason)")
    }

    /// Guards a call that needs `initialize(with:)` to have been called first.
    ///
    /// Calling the SDK before initialising it is a mistake in the app's code, not a runtime condition,
    /// so it is handled the way Swift handles programmer errors: `assertionFailure` stops a debug build
    /// on the first run with the message, where a log line could be overlooked (Firebase and RevenueCat
    /// do the same for their configure calls). A release build only logs and carries on, because the
    /// order of calls in a real app is not always deterministic and an ad SDK must never take the app
    /// down in front of users. Not `throws`: that would put `try` on every publisher's call for a mistake
    /// most never make. AdMob and AppLovin MAX also stay non-throwing and let the ad load fail instead.
    @discardableResult
    func requireInitialized(_ call: String) -> Bool {
        guard !isInitialized else { return true }
        Environment.assertionFailure("KontextVideo: call initialize(with:) before \(call)")
        Logger.error("\(call) called before initialize(with:); no ads will load")
        return false
    }

    /// After a failed `/config`, every ads request tries it again first; a load is already an explicit
    /// request for an ad, and one `/config` per load is cheap.
    private func retryConfig() {
        guard state == .failed, let configuration else { return }
        Logger.info("Retrying /config")
        state = .initializing
        initTask = Task { await fetchConfig(configuration: configuration) }
    }

    /// Back to the state before `initialize(with:)`. Tests only: the shared instance is process-wide.
    // swiftlint:disable:next unused_declaration
    func resetForTesting() {
        initTask?.cancel()
        initTask = nil
        configuration = nil
        state = .notInitialized
        user = nil
        regulatory = nil
        variantId = nil
        adOnScreen = nil
        reportDebug = false
        DebugReporter.shared.isEnabled = false
        Logger.level = .warning
    }

    /// `/config`'s one retry: after a failure that may clear (no network, a 5xx, a 429), the same request
    /// is sent again after `configRetryDelay` seconds, with the same `requestId` so the server replays
    /// rather than registers twice. A 4xx or a malformed answer is not retried. A constant in spirit; a
    /// variable so the tests can shrink the wait (`nonisolated(unsafe)`: a global the test harness writes
    /// before anything runs, the race is accepted, not fixed).
    nonisolated(unsafe) static var configRetryDelay: TimeInterval = 2

    static func sendConfigRequest(_ request: ConfigRequest, client: APIClient) async throws -> ConfigResponse {
        do {
            return try await client.post("config", body: request)
        } catch let error as APIError where error.isRetryable {
            Logger.warning("/config failed (\(error)); retrying in \(configRetryDelay) s")
            try await Task.sleep(nanoseconds: UInt64(configRetryDelay * 1_000_000_000))
            return try await client.post("config", body: request)
        }
    }

    private func fetchConfig(configuration: Configuration) async {
        let client = APIClient(baseURL: configuration.adServerURL)
        let request = ConfigRequest.make(configuration: configuration, installId: Self.installId)
        do {
            let response = try await Self.sendConfigRequest(request, client: client)
            // Cancelled meanwhile (`resetForTesting()`): the answer belongs to a state that was reset.
            guard !Task.isCancelled else { return }
            switch response {
            case .enabled(let reportDebug):
                self.reportDebug = reportDebug
                DebugReporter.shared.isEnabled = reportDebug
                DebugReporter.shared.event("config.response", state: ["enabled": true])
                state = .enabled
                Logger.info("Enabled")
            case .disabled(let reason):
                state = .disabled(reason: reason)
                Logger.warning("Disabled by the server: \(reason)")
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
            Logger.error("/config failed, no ads until it succeeds: \(error)")
        }
    }
}
