import KontextKit

/// The Kontext Video SDK's entry point, the one shared instance an app talks to: `initialize(with:)` once at launch,
/// then the viewer's facts (`user`, `regulatory`) whenever they change, and `state` to read.
///
/// Why one shared instance: the SDK has one configuration, one `/config` and one ad on screen per app, as
/// established ad SDKs do. It is the shell around `SdkState`: it starts `/config` (`ConfigFetcher`), retries it
/// before an ads request after a failure (`waitUntilEnabled`), and applies the kill switch. Ads come from a
/// `VideoAds` per video, which asks it whether ads may be requested.
///
/// ```
/// initialize ──► .initializing ──/config──► .enabled ──(an ads answer's kill switch)──► .disabled
///                                     ├────► .disabled (the server said so)
///                                     └────► .failed ──(the next format())──► .initializing
/// ```
@MainActor
public final class KontextVideo {
    /// Whether the SDK may request ads.
    public enum State: Sendable, Equatable {
        /// `initialize(with:)` was not called yet.
        case notInitialized
        /// `/config` is in flight. Ads requests wait for it.
        case initializing
        /// `/config` succeeded: ads may be requested.
        case enabled
        /// The server switched the SDK off. Final for this app launch.
        case disabled(reason: String)
        /// `/config` failed (one attempt: no network, an error status, a malformed answer). No ads until a later
        /// `/config` succeeds: every ads request tries it again first.
        case failed
    }

    /// The one instance. Every public call goes through it.
    public static let shared = KontextVideo()

    /// The SDK's version, the same string it sends with every request. For your logs and crash reports.
    public nonisolated static let version = SDKInfo.version

    /// Identifies this installation of the app, sent with every request. Created on first use and kept until
    /// the app is uninstalled. Internal: an app has no use for it, and must not reuse it as its own user id.
    static var installId: String {
        InstallIdProvider.getOrCreate()
    }

    /// The SDK's own facts, the one source of truth: its phase, the configuration, what `/config` said of the
    /// reports. `KontextVideo` is the shell that moves it.
    private(set) var sdkState = SdkState()

    /// The configuration the SDK was initialised with, or `nil` before `initialize(with:)`.
    var configuration: Configuration? { sdkState.configuration }
    /// Where the SDK is, readable at any time. `initialize(with:)` reports it once `/config` answered; it can
    /// change later: an ads response may switch the SDK off (`.disabled`), and the next `format(_:)` after a
    /// failed `/config` tries again (`.failed`, then `.initializing`). Read it, for example, to hide your ad UI
    /// once the SDK is disabled. Nothing notifies a change: read it when you decide.
    public var state: State { sdkState.phase }

    /// The viewer: required before the first ads request, whose `format(_:)` otherwise throws
    /// `request(.missingUser)` without sending anything (a debug build stops on an assertion). Set it as soon as
    /// you know who watches (a guest id the app keeps, then the account id after login); the next ads request
    /// carries it. Ads already loaded or fetched keep the targeting they were requested with.
    public var user: User? {
        get { sdkState.user }
        set {
            sdkState.recordUser(newValue)
            IntegrationGuard.checkUser(newValue)
        }
    }
    /// Privacy and consent signals. Set what your consent platform gives you; `coppa` can only come from you.
    /// The next ads request carries them; ads already loaded stay. Setting it to `nil` clears your values
    /// only: the SDK still reads the CMP's shared storage on every request.
    public var regulatory: Regulatory? {
        get { sdkState.regulatory }
        set { sdkState.recordRegulatory(newValue) }
    }

    /// Whether `initialize(with:)` was called; not whether `/config` succeeded, which is `state`.
    var isInitialized: Bool { sdkState.isInitialized }

    /// The one ad on screen in the whole app, from any `VideoAds` (`ScreenSlot`).
    var adOnScreen: VideoAd? { ScreenSlot.current }

    /// The server's reason while the SDK is switched off, else `nil`.
    var disabledReason: String? { sdkState.disabledReason }

    private var initTask: Task<Void, Never>?

    private init() {}

    /// Starts the SDK: stores the configuration and calls `/config` in the background.
    /// Call it once, at app launch; a later call's configuration is ignored. `completion` runs on the main
    /// thread once `/config` has answered or failed, for a later call too: with the first call's state.
    /// It is the optional "tell me when the SDK is ready", rarely needed: ads wait for `/config` by themselves,
    /// so an app may initialize and request ads at once. For an app that wants the result, to log it or to skip
    /// ad UI when the SDK is disabled; the `async` overload returns the same state.
    public func initialize(with configuration: Configuration, completion: ((State) -> Void)? = nil) {
        guard !isInitialized else {
            Logger.warning("initialize(with:) was already called; this call's configuration is ignored")
            // A caller waiting on its callback must still hear: once the first call's `/config` is done.
            if let completion {
                let first = initTask
                Task {
                    await first?.value
                    completion(state)
                }
            }
            return
        }
        sdkState.recordConfiguration(configuration)
        Logger.level = configuration.logLevel
        // An unusable configuration still tries `/config`; a server that answers wants to hear about it.
        IntegrationGuard.checkConfiguration(configuration)
        Logger.debug("Initialising, SDK version \(Self.version)")
        sdkState.moveTo(.initializing)
        initTask = Task {
            await fetchConfig(configuration: configuration)
            // Cancelled by `resetForTesting()`: the state is no longer this call's to report.
            guard !Task.isCancelled else { return }
            completion?(state)
        }
    }

    /// The same, for `async` code: returns the state once `/config` has answered or failed. Swift picks
    /// this overload in an `async` context and the fire-and-forget one elsewhere.
    @discardableResult
    public func initialize(with configuration: Configuration) async -> State {
        initialize(with: configuration, completion: nil)
        await initTask?.value
        return state
    }

    /// Whether ads may be requested now: waits while `/config` is in flight, retries it first after a
    /// failure, and answers `false` when the SDK is off. Every caller waits for the same `/config`; a
    /// cancelled caller (a destroyed `VideoAds`) stops waiting at once with `CancellationError`, and
    /// `/config` goes on for the others.
    func waitUntilEnabled() async throws -> Bool {
        if state == .failed {
            retryConfig()
        }
        if state == .initializing, let initTask {
            try await awaitShared(initTask)
        }
        return state == .enabled
    }

    /// An ads response said `enabled: false`: the same kill switch as `/config`.
    func disable(reason: String) {
        guard sdkState.moveTo(.disabled(reason: reason)) else { return }
        Logger.warning("Disabled by the server: \(reason)")
        VideoAds.sdkWasDisabled()
    }

    /// After a failed `/config`, every ads request tries it again first; a load is already an explicit
    /// request for an ad, and one `/config` per load is cheap.
    private func retryConfig() {
        guard let configuration, sdkState.moveTo(.initializing) else { return }
        Logger.info("Retrying /config")
        initTask = Task { await fetchConfig(configuration: configuration) }
    }

    /// `/config`'s `reportErrors`, recorded in `sdkState`; `ErrorReporter` sends, keeps or drops its reports by it.
    func recordErrorReporting(_ isOn: Bool) {
        sdkState.recordErrorReporting(isOn)
        ErrorReporter.shared.reportingChanged()
    }

    /// `/config`'s `reportDebug`, recorded in `sdkState`; `DebugReporter` sends its events or drops them by it.
    func recordDebugReporting(_ isOn: Bool) {
        sdkState.recordDebugReporting(isOn)
        DebugReporter.shared.reportingChanged()
    }

    /// Back to the state before `initialize(with:)`. Tests only: the shared instance is process-wide.
    func resetForTesting() { // swiftlint:disable:this unused_declaration
        initTask?.cancel()
        initTask = nil
        sdkState = SdkState()
        ScreenSlot.resetForTesting()
        DebugReporter.shared.resetForTesting()
        ErrorReporter.shared.resetForTesting()
        Logger.level = .warning
    }

    /// `/config`, once (`ConfigFetcher`), and what its answer does to the SDK.
    private func fetchConfig(configuration: Configuration) async {
        let outcome = await ConfigFetcher.fetch(configuration)
        switch outcome {
        case .cancelled:
            return
        case .failed:
            sdkState.moveTo(.failed)
        case .answered(let response):
            switch response {
            case .enabled(let reporting):
                ErrorReporter.shared.interval = reporting.errorBatchInterval
                DebugReporter.shared.interval = reporting.debugBatchInterval
                recordDebugReporting(reporting.reportDebug)
                recordErrorReporting(reporting.reportErrors)
                DebugReporter.shared.event("config.response", properties: ["enabled": true])
                sdkState.moveTo(.enabled)
                Logger.info("Enabled")
                // The browser user agent every ads request carries, evaluated in a WebView once per process.
                // Started now, so the first request rarely waits for it; not at `initialize`, so an app whose
                // SDK the server switches off never makes that WebView.
                UserAgent.startLookup()
            case .disabled(let reason):
                sdkState.moveTo(.disabled(reason: reason))
                recordErrorReporting(false)
                Logger.warning("Disabled by the server: \(reason)")
            }
        }
    }
}
