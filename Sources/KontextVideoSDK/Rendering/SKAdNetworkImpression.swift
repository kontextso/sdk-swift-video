import KontextKit

/// The SKAdNetwork side of one app-install ad: Apple's view-through impression, registered when the
/// creative appears and ended when it leaves, and the App Store product sheet a click opens with the
/// network's fidelity-1 signature. One per `VideoAd` whose ad carries `attribution.skan`.
///
/// Attribution is best effort: every failure is logged and reported, none reaches the app, and the ad
/// itself is not affected. Apple's APIs are called one at a time, in the order the ads asked, through
/// one queue for the whole app: the manager behind them holds one impression, and the next ad's start
/// must not overtake the previous ad's end.
@MainActor
final class SKAdNetworkImpression {
    let skan: Skan
    private let adId: String
    /// `start()` ran; nothing is called twice.
    private var started = false
    private var ended = false
    /// Apple accepted the impression: only then is there something to end.
    private var registered = false
    /// The last call queued, for the next one to wait on. Tests clear it.
    static var queue: Task<Void, Never>?

    init(skan: Skan, adId: String) {
        self.skan = skan
        self.adId = adId
    }

    /// The creative is on screen: the `SKAdImpression` is registered and started. Once.
    func start() {
        guard !started else { return }
        started = true
        enqueue { [self] in
            do {
                try await Environment.skAdNetwork.initImpression(skan)
                registered = true
                // The ad left the screen while Apple registered it: no start for an ad nobody sees; the
                // end already queued behind this releases the impression.
                guard !ended else { return }
                try await Environment.skAdNetwork.startImpression()
                Logger.info("ad \(adId.prefix(8)): SKAdNetwork impression started")
            } catch {
                report("start", error)
            }
        }
    }

    /// The creative left the screen: the impression is ended and released. Once; after `start()`'s calls.
    func end() {
        guard started, !ended else { return }
        ended = true
        enqueue { [self] in
            guard registered else { return }
            registered = false
            do {
                try await Environment.skAdNetwork.endImpression()
                Logger.info("ad \(adId.prefix(8)): SKAdNetwork impression ended")
            } catch {
                report("end", error)
            }
            // Released whatever the end did: a failed end must not leave the impression behind for the next ad.
            do {
                try await Environment.skAdNetwork.dispose()
            } catch {
                report("dispose", error)
            }
        }
    }

    /// The viewer tapped the ad: the App Store product sheet, signed so the install is attributed to the
    /// click. `false` when the network did not sign the click or the sheet could not be presented; the
    /// caller opens the click URL then.
    func presentStore() async -> Bool {
        guard skan.hasFidelity1 else { return false }
        do {
            let presented = try await Environment.storeProduct.present(skan)
            if !presented { Logger.warning("ad \(adId.prefix(8)): the App Store sheet was not presented") }
            return presented
        } catch {
            report("store", error)
            return false
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = Self.queue
        Self.queue = Task {
            await previous?.value
            await operation()
        }
    }

    private func report(_ step: String, _ error: Error) {
        Logger.warning("ad \(adId.prefix(8)): SKAdNetwork \(step) failed: \(error)")
        DebugReporter.shared.event("ad.skanFailed", adId: adId, level: .warning, state: ["step": .string(step), "error": .string("\(error)")])
    }
}

/// Apple's impression lifecycle: register, start when the ad is displayed, end when it is gone, release.
@MainActor
protocol SKAdNetworkManaging {
    func initImpression(_ skan: Skan) async throws
    func startImpression() async throws
    func endImpression() async throws
    func dispose() async throws
}

/// The App Store product sheet with the ad's fidelity-1 attribution; `true` once it is on screen.
@MainActor
protocol StoreProductManaging {
    func present(_ skan: Skan) async throws -> Bool
}

/// KontextKit's managers, the same sdk-swift uses: `SKAdNetworkManager.shared` holds the one impression,
/// `SKStoreProductManager.shared` presents from the top view controller.
struct KontextKitSKAdNetwork: SKAdNetworkManaging {
    func initImpression(_ skan: Skan) async throws {
        try await SKAdNetworkManager.shared.initImpression(params: skan.rawDictionary())
    }

    func startImpression() async throws {
        _ = try await SKAdNetworkManager.shared.startImpression()
    }

    func endImpression() async throws {
        _ = try await SKAdNetworkManager.shared.endImpression()
    }

    func dispose() async throws {
        try await SKAdNetworkManager.shared.dispose()
    }
}

struct KontextKitStoreProduct: StoreProductManaging {
    func present(_ skan: Skan) async throws -> Bool {
        try await SKStoreProductManager.shared.present(skan: skan.rawDictionary())
    }
}
