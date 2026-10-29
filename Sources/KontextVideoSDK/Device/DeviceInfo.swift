import KontextKit

/// The `os` object of a request. KontextKit's names are the API's: `ios`, `ipados`, `tvos`.
struct OSInfo: Encodable, Sendable {
    let name: OSInfoProvider.OSName
    let version: String
    /// BCP-47, for example "cs-CZ".
    let locale: String
    /// IANA, for example "Europe/Prague".
    let timezone: String

    @MainActor
    static func current() -> OSInfo {
        let info = OSInfoProvider.collect()
        return OSInfo(name: info.name, version: info.version, locale: info.locale, timezone: info.timezone)
    }
}

/// The `hardware` object of a request. KontextKit's types are the API's OpenRTB-derived set (`phone`,
/// `tablet`, `tv`, `desktop`, `other`; `settopbox` never applies to Apple hardware).
struct HardwareInfo: Encodable, Sendable {
    let brand: String
    /// The model identifier, for example "iPhone16,1".
    let model: String
    let type: HardwareInfoProvider.HardwareType

    @MainActor
    static func current() -> HardwareInfo {
        let info = HardwareInfoProvider.collect()
        return HardwareInfo(brand: info.brand, model: info.model, type: info.type)
    }
}

/// The `app` object of a request.
struct AppInfo: Encodable, Sendable {
    let bundleId: String
    let version: String

    static func current() -> AppInfo {
        let info = AppInfoProvider.collect()
        return AppInfo(bundleId: info.bundleId, version: info.version)
    }
}

/// The SKAdNetwork ids and AdAttributionKit identifiers from the app's Info.plist,
/// so the server knows which DSPs can be attributed.
struct AttributionIds: Encodable, Sendable {
    let skan: [String]
    let aak: [String]

    static func current() -> AttributionIds {
        AttributionIds(
            skan: SKAdNetworkIdsProvider.collect(),
            aak: AdAttributionKitIdsProvider.collect()
        )
    }
}

/// The `screen` object of an ads request, in points; the server multiplies by `dpr` where OpenRTB wants
/// physical pixels.
struct ScreenInfo: Encodable, Sendable {
    let width: Int
    let height: Int
    let dpr: Double
    let darkMode: Bool

    @MainActor
    static func current() -> ScreenInfo {
        let info = ScreenInfoProvider.collect()
        return ScreenInfo(width: info.width, height: info.height, dpr: info.dpr, darkMode: info.darkMode)
    }
}

/// The `power` object of an ads request.
struct PowerInfo: Encodable, Sendable {
    /// 0–100; `nil` when the device does not report it.
    let batteryLevel: Int?
    let batteryState: String
    let lowPowerMode: Bool

    @MainActor
    static func current() -> PowerInfo {
        let info = BatteryInfoProvider.collect()
        return PowerInfo(batteryLevel: info.batteryLevel.map { Int($0.rounded()) }, batteryState: info.batteryState, lowPowerMode: info.lowPowerMode)
    }
}

/// The `audio` object of an ads request.
struct AudioInfo: Encodable, Sendable {
    /// 0–100.
    let volume: Int
    let muted: Bool

    /// KontextKit's read of the system volume, below 1 % counted as muted. A read only since KontextKit
    /// 0.4.0: it leaves the shared audio session, which belongs to the app's player, as the app set it.
    @MainActor
    static func current() -> AudioInfo {
        let info = AudioInfoProvider.collect()
        return AudioInfo(volume: info.volume, muted: info.muted)
    }
}

/// The `network` object of an ads request: the browser's user agent (`navigator.userAgent` of a WebView),
/// as sdk-swift sends it; `nil` when WebKit could not answer.
struct NetworkInfo: Encodable, Sendable {
    let userAgent: String?

    /// The one lookup in flight, or done with a value: KontextKit makes a WebView for every call until it has
    /// cached the answer, so the SDK asks once and every request waits for that.
    @MainActor static var lookup: Task<String?, Never>?

    /// Waits for the user agent. A cancelled caller (a request whose `VideoAds` was destroyed) stops waiting
    /// at once, with no user agent, and the lookup goes on for the others; the request then finds its owner
    /// gone and sends nothing. A lookup that found none is tried again by the next caller.
    @MainActor
    static func current() async -> NetworkInfo {
        let task = lookup ?? Task { await Environment.userAgent() }
        lookup = task
        do {
            let userAgent = try await awaitShared(task)
            if userAgent == nil, lookup == task { lookup = nil }
            return NetworkInfo(userAgent: userAgent)
        } catch {
            return NetworkInfo(userAgent: nil)
        }
    }
}
