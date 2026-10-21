import AppTrackingTransparency
import Foundation
import KontextKit
import UIKit

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
        /// every ads request retries it first, whenever it comes.
        case failed
    }

    /// The one instance. Every public call goes through it, as `GADMobileAds.sharedInstance()` or `ALSdk.shared()`.
    public static let shared = KontextVideo()

    /// The SDK's version, the same string it sends with every request. For your logs and crash reports.
    public nonisolated static let version = SDKInfo.version

    /// Identifies this installation of the app. Created on first use and kept until the app is uninstalled.
    public static var installId: String {
        InstallIdProvider.getOrCreate()
    }

    /// The configuration the SDK was initialised with, or `nil` before `initialize(with:)`.
    public private(set) var configuration: Configuration?
    /// Where `/init` got to. Readable at any time; `initialize(with:)`'s completion or `async` form delivers it too.
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

    /// Whether `initialize(with:)` was called; not whether `/init` succeeded, which is `state`.
    public var isInitialized: Bool {
        configuration != nil
    }

    /// When the server asked for the debug log (`reportDebug` in the `/init` response).
    private(set) var reportDebug = false
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
        observeTrackingAuthorization()
        initTask = Task {
            await runInit(configuration: configuration)
            completion?(state)
        }
    }

    /// The same, for `async` code: returns the state once `/init` has answered or failed, as AdMob's
    /// `await MobileAds.shared.start()`. Swift picks this overload in an `async` context and the
    /// fire-and-forget one elsewhere.
    public func initialize(with configuration: Configuration) async -> State {
        initialize(with: configuration, completion: nil)
        await initTask?.value
        return state
    }

    /// Every `VideoAds` registers itself here from its initializer, so the rules that touch all of them
    /// (a targeting change discards every unshown ad) can reach it.
    func register(_ ads: VideoAds) {
        requireInitialized("VideoAds(content:playerSize:)")
        liveVideoAds.append(WeakVideoAds(ads))
        liveVideoAds.removeAll { $0.value == nil }
    }

    /// Every `VideoAds` still alive, for the rules that touch all of them.
    private var liveVideoAds: [WeakVideoAds] = []

    private struct WeakVideoAds {
        weak var value: VideoAds?
        init(_ value: VideoAds) { self.value = value }
    }

    /// Whether ads may be requested now: waits while `/init` is in flight, retries it first after a
    /// failure, and answers `false` when the SDK is off.
    func waitUntilEnabled() async -> Bool {
        if state == .failed {
            retryInit()
        }
        if state == .initializing {
            await initTask?.value
        }
        return state == .enabled
    }

    /// An ads response said `enabled: false`: the same kill switch as `/init`.
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

    /// After a failed `/init`, every ads request tries it again first; a load is already an explicit
    /// request for an ad, and one `/init` per load is cheap.
    private func retryInit() {
        guard state == .failed, let configuration else { return }
        Logger.info("Retrying /init")
        state = .initializing
        initTask = Task { await runInit(configuration: configuration) }
    }

    /// The ATT status is the fourth targeting input, and the only one the app does not set. The last
    /// value the SDK acted on; read when `shared` is first touched, which may be before the app's own
    /// ATT prompt, and that is fine: the first comparison then sees the answer as a change.
    private var lastTrackingStatus = ATTrackingManager.trackingAuthorizationStatus
    /// The `didBecomeActive` subscription. The token is the subscription: kept so a second call cannot
    /// add a second observer, and so it could be removed; `shared` lives as long as the app, so it never is.
    private var activityObserver: (any NSObjectProtocol)?

    /// Re-reads the ATT status whenever the app becomes active, because it can change while the app is
    /// not: the viewer flips the switch in Settings > Privacy > Tracking (the app is in the background
    /// for that), or an ATT prompt is answered (a system dialog, during which the app is not active),
    /// whether the publisher's own or the SDK's. Nothing tells the SDK; `didBecomeActiveNotification`
    /// is the moment to look. A changed status is a targeting change like `user`, `regulatory` and
    /// `variantId`: the IFA may now be present or gone, so every prefetched ad was requested with stale
    /// targeting and is discarded (`noteTrackingAuthorization`, which the SDK's own prompt path in
    /// `VideoAds.fetch` also calls, so both routes end in one place).
    private func observeTrackingAuthorization() {
        guard activityObserver == nil else { return }
        activityObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteTrackingAuthorization(ATTrackingManager.trackingAuthorizationStatus) }
        }
    }

    /// Called with a freshly read status; discards pending ads when it differs from the last one seen.
    func noteTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {
        guard status != lastTrackingStatus else { return }
        lastTrackingStatus = status
        targetingChanged("ATT status")
    }

    /// The spec's rule: when `user`, `regulatory`, `variantId` or the ATT status changes, every loaded
    /// ad that was not shown yet is discarded, and the next request for each format carries the new values.
    private func targetingChanged(_ what: String) {
        Logger.debug("\(what) changed")
        for entry in liveVideoAds {
            entry.value?.discardLoadedAds(reason: "\(what) changed")
        }
    }

    /// Back to the state before `initialize(with:)`. Tests only: the shared instance is process-wide.
    func resetForTesting() {
        initTask?.cancel()
        initTask = nil
        configuration = nil
        state = .notInitialized
        user = nil
        regulatory = nil
        variantId = nil
        reportDebug = false
        liveVideoAds.removeAll()
        DebugReporter.shared.isEnabled = false
        Logger.level = .warning
    }

    /// `/init`'s one retry: after a failure that may clear (no network, a 5xx, a 429), the same request
    /// is sent again after `initRetryDelay` seconds, with the same `requestId` so the server replays
    /// rather than registers twice. A 4xx or a malformed answer is not retried. A constant in spirit; a
    /// variable so the tests can shrink the wait (`nonisolated(unsafe)`: a global the test harness writes
    /// before anything runs, the race is accepted, not fixed).
    nonisolated(unsafe) static var initRetryDelay: TimeInterval = 2

    static func sendInit(_ request: InitRequest, client: APIClient) async throws -> InitResponse {
        do {
            return try await client.post("init", body: request)
        } catch let error as APIError where error.isRetryable {
            Logger.warning("/init failed (\(error)); retrying in \(initRetryDelay) s")
            try await Task.sleep(nanoseconds: UInt64(initRetryDelay * 1_000_000_000))
            return try await client.post("init", body: request)
        }
    }

    private func runInit(configuration: Configuration) async {
        let client = APIClient(baseURL: configuration.adServerURL)
        let request = InitRequest.make(configuration: configuration, installId: Self.installId)
        do {
            switch try await Self.sendInit(request, client: client) {
            case .enabled(let reportDebug):
                self.reportDebug = reportDebug
                DebugReporter.shared.isEnabled = reportDebug
                DebugReporter.shared.event("init.response", state: ["enabled": true])
                state = .enabled
                Logger.info("Enabled")
            case .disabled(let reason):
                state = .disabled(reason: reason)
                Logger.warning("Disabled by the server: \(reason)")
            }
        } catch {
            state = .failed
            Logger.error("/init failed, no ads until it succeeds: \(error)")
        }
    }
}
