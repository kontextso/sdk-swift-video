import Foundation
import UIKit

/// The body of `POST /video/ads`: every format, for one video, for one `VideoAds` session.
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
    /// `VideoAds.labels` as the request began; left out when there are none.
    let labels: [String: String]?
    /// One per `VideoAds`: the server keeps the bids it gave out per session.
    let sessionId: String
    /// Ids of the unshown bids the SDK holds: the server re-serves them, anything else it gave this session
    /// is spent.
    let held: [String]

    private enum CodingKeys: String, CodingKey {
        case requestId, publisherToken, installId, user, variantId, ifa, idfv, attStatus, regulatory, sdk, app, device, player, video, labels, sessionId, held
    }

    @MainActor
    static func make(sdk: KontextVideo, configuration: KontextVideo.Configuration, tracking: TrackingInfo, content: KontextVideo.Content, labels: [String: String], player: PlayerSnapshot, sessionId: String, held: [String]) async -> AdsRequest {
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
            // A usable CMP value wins per field; the publisher fills in the rest. COPPA comes only from the publisher.
            regulatory: ConsentStorage.read(merging: sdk.regulatory),
            sdk: SDKInfo(),
            app: .current(),
            device: await .current(),
            player: player,
            video: content,
            labels: labels.isEmpty ? nil : labels,
            sessionId: sessionId,
            held: held
        )
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
    static func current() async -> AdsDevice {
        AdsDevice(os: .current(), hardware: .current(), screen: .current(), power: .current(), audio: .current(), network: await .current())
    }
}

/// What an ads request says about the player: the SDK assumes a full-screen player, so the screen in its
/// current orientation, and the playhead read at request time. `show` fits the ad into the real view.
struct PlayerSnapshot: Encodable, Sendable, Equatable {
    let width: Int
    let height: Int
    let fullscreen: Bool
    /// Milliseconds in content time; 0 before the episode plays.
    let playhead: Int

    /// The key window's size, or the screen's, in points: width < height is portrait. `playhead` in
    /// seconds, as the SDK keeps it; the wire takes milliseconds.
    @MainActor
    static func make(playhead: TimeInterval) -> PlayerSnapshot {
        let screen = (Environment.keyWindow()?.bounds ?? UIScreen.main.bounds).size
        return PlayerSnapshot(width: Int(screen.width.rounded()), height: Int(screen.height.rounded()), fullscreen: true,
                              playhead: Int((playhead * 1000).rounded()))
    }
}
