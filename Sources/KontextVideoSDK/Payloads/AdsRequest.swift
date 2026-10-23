import Foundation
import KontextKit
import UIKit

/// The body of `POST /video/ads`: the formats asked for, each with its options, for one video.
struct AdsRequest: Encodable, Sendable {
    /// One entry of `formats`: `{ format, options }`, the options in the shape of their format.
    struct Format: Encodable, Sendable, Equatable {
        let request: FormatRequest

        private enum CodingKeys: String, CodingKey {
            case format, options
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(request.format, forKey: .format)
            switch request {
            case .overlay(let options): try container.encode(options, forKey: .options)
            case .pause(let options): try container.encode(options, forKey: .options)
            case .linear(let options): try container.encode(options, forKey: .options)
            }
        }
    }

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
    let regulatory: Regulatory?
    let sdk: SDKInfo
    let app: AppInfo
    let device: AdsDevice
    let player: PlayerSnapshot
    let video: KontextVideo.Content
    /// Each format at most once.
    let formats: [Format]

    private enum CodingKeys: String, CodingKey {
        case requestId, publisherToken, installId, user, variantId, ifa, idfv, attStatus, regulatory, sdk, app, device, player, video, formats
    }

    @MainActor
    static func make(sdk: KontextVideo, configuration: KontextVideo.Configuration, tracking: TrackingInfo, content: KontextVideo.Content, player: PlayerSnapshot, formats: [FormatRequest]) -> AdsRequest {
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
            // The CMP's shared storage wins per field; what the publisher set fills the rest; coppa from the configuration.
            regulatory: ConsentStorage.read(merging: sdk.regulatory, coppa: configuration.coppa),
            sdk: SDKInfo(),
            app: .current(),
            device: .current(),
            player: player,
            video: content,
            formats: formats.map(Format.init)
        )
    }

    /// The `regulatory` object: the consent signals plus `coppa`, which the app sets once in the configuration.
    struct Regulatory: Encodable, Sendable, Equatable {
        var gdpr: Bool?
        var gdprConsent: String?
        var coppa: Bool?
        var gpp: String?
        var gppSid: [Int]?
        var usPrivacy: String?
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
