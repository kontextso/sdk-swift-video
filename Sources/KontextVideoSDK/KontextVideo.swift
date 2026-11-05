import KontextKit

/// Entry point of the Kontext Video SDK.
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

    /// What the publisher knows about the viewer. Set it whenever you learn it, for example after login;
    /// the next ads request carries it. Ads already loaded or fetched keep the targeting they were requested with.
    public var user: User? {
        didSet {
            guard let empty = user?.emptyFields, !empty.isEmpty else { return }
            if empty.contains("id") { Environment.assertionFailure("KontextVideo.User: id is empty") }
            Logger.warning("user: \(empty.joined(separator: ", ")) empty, left out of the requests")
        }
    }
    /// Privacy and consent signals. Set what your consent platform gives you; `coppa` can only come from you.
    /// The next ads request carries them; ads already loaded stay. Setting it to `nil` clears your values
    /// only: the SDK still reads the CMP's shared storage on every request.
    public var regulatory: Regulatory?
    /// Selects which type of ad to render, for A/B testing. Agreed between the publisher and Kontext.
    public var variantID: String?

    /// Whether `initialize(with:)` was called; not whether `/config` succeeded, which is `state`.
    var isInitialized: Bool { sdkState.isInitialized }

    /// The one ad on screen in the whole app, from any `VideoAds`: taken at `show`, released at `didEnd`; it
    /// retains the ad until then, whatever the app does with its reference.
    var shownAd: ShownAd?
    var adOnScreen: VideoAd? { shownAd?.ad }

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
        if !configuration.problems.isEmpty {
            // A configuration mistake: every request would fail. Stops a debug build here, not at a 400 later.
            Environment.assertionFailure("KontextVideo.Configuration: \(configuration.problems.joined(separator: ", "))")
            Logger.error("configuration: \(configuration.problems.joined(separator: ", ")); no ads will load")
            // An unusable configuration still tries `/config`; a server that answers wants to hear about it.
            if configuration.publisherToken.isEmpty { ErrorReporter.shared.report(.emptyToken, stage: .integration) }
            if configuration.problems.contains(where: { $0.hasPrefix("adServerURL") }) {
                ErrorReporter.shared.report(.badServerURL, stage: .integration)
            }
        }
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
    }

    /// Guards a call that needs `initialize(with:)` to have been called first.
    ///
    /// Calling the SDK before initialising it is a mistake in the app's code, not a runtime condition,
    /// so it is handled the way Swift handles programmer errors: `assertionFailure` stops a debug build
    /// on the first run with the message, where a log line could be overlooked (a common choice for an
    /// SDK's configure call). A release build only logs and carries on, because the
    /// order of calls in a real app is not always deterministic and the SDK must not take the app down in
    /// front of users. Not `throws`: that would put `try` on every publisher's call for a mistake most
    /// never make.
    @discardableResult
    func requireInitialized(_ call: String) -> Bool {
        guard !isInitialized else { return true }
        Environment.assertionFailure("KontextVideo: call initialize(with:) before \(call)")
        Logger.error("\(call) called before initialize(with:); no ads will load")
        // Kept in memory: it leaves if the app initializes later and `/config` turns the reports on.
        ErrorReporter.shared.report(.notInitialized, stage: .integration, detail: call)
        return false
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
        user = nil
        regulatory = nil
        variantID = nil
        shownAd = nil
        DebugReporter.shared.resetForTesting()
        ErrorReporter.shared.resetForTesting()
        Logger.level = .warning
    }

    /// One attempt, whatever the failure: no retry policy for now, every request is sent once. After a failure
    /// the SDK is `.failed`, and the next ads request tries `/config` again (`waitUntilEnabled`).
    static func sendConfigRequest(_ request: ConfigRequest, client: APIClient) async throws -> ConfigResponse {
        try await client.post("config", body: request)
    }

    private func fetchConfig(configuration: Configuration) async {
        let client = APIClient(baseURL: configuration.adServerURL)
        let request = ConfigRequest.make(configuration: configuration, installId: Self.installId)
        do {
            let response = try await Self.sendConfigRequest(request, client: client)
            // Cancelled meanwhile (`resetForTesting()`): the answer belongs to a state that was reset.
            guard !Task.isCancelled else { return }
            switch response {
            case .enabled(let reportDebug, let reportErrors):
                recordDebugReporting(reportDebug)
                recordErrorReporting(reportErrors)
                DebugReporter.shared.event("config.response", state: ["enabled": true])
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
        } catch {
            guard !Task.isCancelled else { return }
            sdkState.moveTo(.failed)
            Logger.error("/config failed, no ads until it succeeds: \(error)")
            // Waits in memory: it leaves once a later `/config` turns the reports on.
            let failure = ErrorReport.FailedRequest(error)
            ErrorReporter.shared.report(.configFailed, stage: .config, requestId: request.requestId, failure: failure)
        }
    }
}

/// The configuration's check, next to `initialize(with:)`, which makes it.
extension KontextVideo.Configuration {
    /// What is wrong with the options, one phrase each; empty when they are usable.
    var problems: [String] {
        var problems: [String] = []
        if publisherToken.isEmpty { problems.append("publisherToken is empty") }
        if adServerURL.scheme == nil || (adServerURL.host ?? "").isEmpty { problems.append("adServerURL \(adServerURL) is not absolute") }
        return problems
    }
}
