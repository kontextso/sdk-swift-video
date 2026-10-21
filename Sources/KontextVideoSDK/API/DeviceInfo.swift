import Foundation
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
