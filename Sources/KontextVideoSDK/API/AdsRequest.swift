import Foundation
import KontextKit
import UIKit

/// The body of `POST /video/ads`: one ad of one format for one video.
struct AdsRequest: Encodable, Sendable {
    /// Where to send it; not part of the body.
    let adServerURL: URL
    let requestId: String
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

/// The `options` object of a request, tagged with its format. Public only because `PlacementOptions`
/// names it; an app never builds one.
public enum FormatOptions: Encodable, Sendable, Equatable {
    case overlay(OverlayOptions)
    case pause(PauseOptions)
    case linear(LinearOptions)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .overlay(let options): try container.encode(options)
        case .pause(let options): try container.encode(options)
        case .linear(let options): try container.encode(options)
        }
    }
}

/// The `device` object of an ads request: what `/config` sends, plus screen, power, audio and network.
struct AdsDevice: Encodable, Sendable {
    let os: OSInfo
    let hardware: HardwareInfo
    let screen: ScreenInfo
    let power: PowerInfo
    let audio: AudioInfo
    let network: NetworkInfo

    @MainActor
    static func current() -> AdsDevice {
        AdsDevice(os: .current(), hardware: .current(), screen: .current(), power: .current(), audio: .current(), network: .current())
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
