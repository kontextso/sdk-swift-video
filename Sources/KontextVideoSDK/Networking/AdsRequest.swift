import Foundation
import KontextKit
import UIKit

/// The body of `POST /video/ads`: one ad of one format for one video.
struct AdsRequest: Encodable, Sendable {
    let requestId: String
    let publisherToken: String
    let installId: String
    let user: User?
    let variantId: String?
    let idfv: String?
    let regulatory: Regulatory?
    let sdk: SDKInfo
    let app: AppInfo
    let device: AdsDevice
    let player: Player
    let video: Video
    let format: AdFormat
    let options: FormatOptions?

    @MainActor
    static func make(configuration: Configuration, installId: String, video: Video, player: Player, format: FormatRequest) -> AdsRequest {
        AdsRequest(
            requestId: UUID().uuidString.lowercased(),
            publisherToken: configuration.publisherToken,
            installId: installId,
            user: configuration.user,
            variantId: configuration.variantId,
            idfv: UIDevice.current.identifierForVendor?.uuidString,
            regulatory: configuration.regulatory,
            sdk: .current,
            app: .current(),
            device: .current(),
            player: player,
            video: video,
            format: format.format,
            options: format.options
        )
    }
}

/// Which format to ask for, with its options.
enum FormatRequest: Sendable, Equatable {
    case overlay(OverlayOptions?)
    case pause(PauseOptions?)
    case interstitial(InterstitialOptions?)

    var format: AdFormat {
        switch self {
        case .overlay: return .overlay
        case .pause: return .pause
        case .interstitial: return .interstitial
        }
    }

    var options: FormatOptions? {
        switch self {
        case .overlay(let options): return options.map(FormatOptions.overlay)
        case .pause(let options): return options.map(FormatOptions.pause)
        case .interstitial(let options): return options.map(FormatOptions.interstitial)
        }
    }
}

/// The `options` object, encoded as whichever format's options it holds.
enum FormatOptions: Encodable, Sendable {
    case overlay(OverlayOptions)
    case pause(PauseOptions)
    case interstitial(InterstitialOptions)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .overlay(let options): try container.encode(options)
        case .pause(let options): try container.encode(options)
        case .interstitial(let options): try container.encode(options)
        }
    }
}

/// The `device` object of an ads request: what `/init` sends, plus screen, power, audio and network.
struct AdsDevice: Encodable, Sendable {
    struct Screen: Encodable, Sendable {
        let width: Int
        let height: Int
        let dpr: Double
        let darkMode: Bool
    }

    struct Power: Encodable, Sendable {
        let batteryLevel: Int?
        let batteryState: String
        let lowPowerMode: Bool
    }

    struct Audio: Encodable, Sendable {
        let volume: Int
        let muted: Bool
    }

    struct Network: Encodable, Sendable {
        let userAgent: String
    }

    let os: OSInfo
    let hardware: HardwareInfo
    let screen: Screen
    let power: Power
    let audio: Audio
    let network: Network

    @MainActor
    static func current() -> AdsDevice {
        let screen = ScreenInfoProvider.collect()
        let battery = BatteryInfoProvider.collect()
        let audio = AudioInfoProvider.collect()
        let app = AppInfo.current()
        let hardware = HardwareInfo.current()
        return AdsDevice(
            os: .current(),
            hardware: hardware,
            // TODO: KontextKit reports the screen in physical pixels, the API wants points; see KontextKit-v2-updates.md, 4.
            screen: Screen(
                width: Int((Double(screen.width) / screen.dpr).rounded()),
                height: Int((Double(screen.height) / screen.dpr).rounded()),
                dpr: screen.dpr,
                darkMode: screen.darkMode
            ),
            power: Power(batteryLevel: battery.batteryLevel.map { Int($0.rounded()) }, batteryState: battery.batteryState, lowPowerMode: battery.lowPowerMode),
            audio: Audio(volume: audio.volume, muted: audio.muted),
            network: Network(userAgent: "\(app.bundleId)/\(app.version) (\(hardware.model); iOS \(UIDevice.current.systemVersion)) KontextVideo/\(SDKInfo.current.version)")
        )
    }
}
