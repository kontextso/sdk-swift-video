import Foundation
import KontextKit
import UIKit

/// The `os` object of a request.
struct OSInfo: Encodable, Sendable {
    enum Name: String, Encodable, Sendable {
        case ios
        case ipados
    }

    let name: Name
    let version: String
    /// BCP-47, for example "cs-CZ".
    let locale: String
    /// IANA, for example "Europe/Prague".
    let timezone: String

    @MainActor
    static func current() -> OSInfo {
        let info = OSInfoProvider.collect()
        // TODO: KontextKit reports "ios" on iPad too; see KontextKit-v2-updates.md, 2.
        return OSInfo(
            name: UIDevice.current.userInterfaceIdiom == .pad ? .ipados : .ios,
            version: info.version,
            locale: info.locale,
            timezone: info.timezone
        )
    }
}

/// The `hardware` object of a request.
struct HardwareInfo: Encodable, Sendable {
    enum DeviceType: String, Encodable, Sendable {
        case phone
        case tablet
        case other
    }

    let brand: String
    /// The model identifier, for example "iPhone16,1".
    let model: String
    let type: DeviceType

    @MainActor
    static func current() -> HardwareInfo {
        let info = HardwareInfoProvider.collect()
        // TODO: KontextKit says "handset", the API says "phone"; see KontextKit-v2-updates.md, 3.
        let type: DeviceType
        switch info.type {
        case "handset": type = .phone
        case "tablet": type = .tablet
        default: type = .other
        }
        return HardwareInfo(brand: info.brand, model: info.model, type: type)
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
            // TODO: KontextKit has no AdAttributionKit provider yet; see KontextKit-v2-updates.md, 1.
            aak: Bundle.main.infoDictionary?["AdNetworkIdentifiers"] as? [String] ?? []
        )
    }
}
