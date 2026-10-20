import Foundation
import KontextKit
import UIKit

/// The body of `POST /video/ads`: one ad of one format for one video.
struct AdsRequest: Encodable, Sendable {
    /// Where to send it; not part of the body.
    let adServerURL: URL
    var requestId: String
    let publisherToken: String
    let installId: String
    let user: KontextVideo.User?
    let variantId: String?
    let ifa: IFA?
    let idfv: String?
    let attStatus: String
    let regulatory: KontextVideo.Regulatory?
    let sdk: SDKInfo
    let app: AppInfo
    let device: AdsDevice
    let player: PlayerSnapshot
    let video: KontextVideo.Content
    let format: AdFormat
    let placementId: String
    let options: FormatOptions?

    private enum CodingKeys: String, CodingKey {
        case requestId, publisherToken, installId, user, variantId, ifa, idfv, attStatus, regulatory, sdk, app, device, player, video, format, placementId, options
    }

    @MainActor
    static func make(sdk: KontextVideo, configuration: KontextVideo.Configuration, tracking: TrackingInfo, content: KontextVideo.Content, player: PlayerSnapshot, format: FormatRequest) -> AdsRequest {
        AdsRequest(
            adServerURL: configuration.adServerURL,
            requestId: UUID().uuidString.lowercased(),
            publisherToken: configuration.publisherToken,
            installId: KontextVideo.installId,
            user: sdk.user,
            variantId: sdk.variantId,
            ifa: tracking.ifa,
            idfv: UIDevice.current.identifierForVendor?.uuidString,
            attStatus: tracking.attStatus,
            // What the publisher set wins per field; the rest comes from the CMP's shared storage.
            regulatory: ConsentStorage.read(merging: sdk.regulatory),
            sdk: SDKInfo(),
            app: .current(),
            device: .current(),
            player: player,
            video: content,
            format: format.format,
            placementId: format.placementId,
            options: format.options
        )
    }
}

/// Which placement to ask for, with the options of its format.
struct FormatRequest: Sendable, Equatable {
    let placementId: String
    let options: FormatOptions

    var format: AdFormat {
        switch options {
        case .overlay: return .overlay
        case .pause: return .pause
        case .linear: return .linear
        }
    }
}

/// The `options` object, encoded as whichever format's options it holds.
enum FormatOptions: Encodable, Sendable, Equatable {
    case overlay(OverlayOptions)
    case pause(PauseOptions)
    case linear(LinearOptions)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .overlay(let options): try container.encode(options)
        case .pause(let options): try container.encode(options)
        case .linear(let options): try container.encode(options)
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
            network: Network(userAgent: "\(app.bundleId)/\(app.version) (\(hardware.model); iOS \(UIDevice.current.systemVersion)) KontextVideo/\(SDKInfo.version)")
        )
    }
}

/// What an ads request says about the player: the size the app gave its `VideoAds`, or the screen's
/// when it gave none, and the playhead read at request time.
struct PlayerSnapshot: Encodable, Sendable, Equatable {
    let width: Int
    let height: Int
    let fullscreen: Bool
    /// Milliseconds in content time; 0 before the episode plays.
    let playhead: Int

    /// `playerSize` in points, `nil` for a full-screen player. A given size is sent as is, `fullscreen`
    /// when it matches the screen.
    @MainActor
    static func make(playerSize: CGSize?, playheadMs: Int) -> PlayerSnapshot {
        let screen = (Environment.keyWindow()?.bounds ?? UIScreen.main.bounds).size
        let size = playerSize ?? screen
        return PlayerSnapshot(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            fullscreen: size.width >= screen.width - 1 && size.height >= screen.height - 1,
            playhead: playheadMs
        )
    }
}
