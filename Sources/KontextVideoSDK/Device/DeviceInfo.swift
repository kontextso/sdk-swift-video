import AVFoundation
import KontextKit
import UIKit

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

    /// Read here, not through KontextKit's `AudioInfoProvider`: its `collect()` sets the shared audio
    /// session's category (`.playback`, mixing with others) and activates it on the first call, which a
    /// video SDK must never do to the app that plays the content. Back to KontextKit once it offers a read
    /// without that side effect. `outputVolume` is the system volume; below 1 % counts as muted, as there.
    @MainActor
    static func current() -> AudioInfo {
        let volume = AVAudioSession.sharedInstance().outputVolume
        return AudioInfo(volume: Int((volume * 100).rounded()), muted: volume < 0.01)
    }
}

/// The `network` object of an ads request: the browser's user agent (`navigator.userAgent` of a WebView),
/// as sdk-swift sends it. KontextKit evaluates it once per process and caches it; `nil` when WebKit could
/// not answer.
struct NetworkInfo: Encodable, Sendable {
    let userAgent: String?

    @MainActor
    static func current() async -> NetworkInfo {
        NetworkInfo(userAgent: await NetworkInfoProvider.collect().userAgent)
    }
}
