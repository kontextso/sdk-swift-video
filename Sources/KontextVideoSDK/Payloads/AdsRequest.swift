import Foundation
import UIKit

/// The body of `POST /video/ads`: every format, for one video, for one `VideoAds` session. Nothing about the ads
/// the SDK holds: the server keeps a session's bids and re-serves an unshown one until it hears its outcome.
struct AdsRequest: Encodable, Sendable {
    /// Where to send it; not part of the body.
    let adServerURL: URL
    let requestId: String
    let publisherToken: String
    let installId: String
    /// Always: the server requires the viewer's id, and no request is built without one.
    let user: UserPayload
    /// The `VideoAds`'s A/B variant; left out when it has none.
    let variantId: String?
    let ifa: IFA?
    let idfv: String?
    let attStatus: String
    let regulatory: RegulatoryPayload?
    let sdk: SDKInfo
    let app: AppInfo
    let device: AdsDevice
    let player: PlayerSnapshot
    let video: ContentPayload
    /// Where in the app the player is, as the `VideoAds` names it; left out when it names none.
    let section: String?
    /// One per `VideoAds`: the server keeps the bids it gave out per session.
    let sessionId: String

    private enum CodingKeys: String, CodingKey {
        case requestId, publisherToken, installId, user, variantId, ifa, idfv, attStatus, regulatory, sdk, app, device, player, video, section, sessionId
    }

    /// Every wait first (the device facts, the user agent among them), then, with nothing left to wait for,
    /// what the viewer or the app may change at any moment: the user, the consent, the tracking status and the
    /// playhead (`tracking` and `player` are read here, after the waits; `player` throws for a `VideoAds` gone
    /// meanwhile). A consent update or an ATT answer made while the request was being built is what it sends.
    /// Without a user (cleared during the waits) it throws `missingUser` and nothing is sent. `section` and
    /// `variantId` are the `VideoAds`'s, left out when the server would refuse them.
    @MainActor
    static func make(sdk: KontextVideo, configuration: KontextVideo.Configuration, tracking: @autoclosure () -> TrackingInfo, content: KontextVideo.Content,
                     section: String?, variantId: String?, player: @autoclosure () throws -> PlayerSnapshot, sessionId: String) async throws -> AdsRequest {
        let device = await AdsDevice.current()
        let tracking = tracking()
        let player = try player()
        guard let user = IntegrationGuard.requireUser(sdk.user) else { throw VideoAdError.request(.missingUser) }
        // A usable CMP value wins per field; the publisher fills in the rest. COPPA comes only from the publisher.
        let regulatory = ConsentStorage.read(merging: sdk.regulatory)
        return AdsRequest(
            adServerURL: configuration.adServerURL,
            requestId: UUID().uuidString.lowercased(),
            publisherToken: configuration.publisherToken,
            installId: KontextVideo.installId,
            user: UserPayload(regulatory.userToSend(user)),
            variantId: VideoAds.sendable(variantId),
            ifa: regulatory.deviceIdentifierToSend(tracking.ifa),
            idfv: regulatory.deviceIdentifierToSend(UIDevice.current.identifierForVendor?.uuidString),
            attStatus: tracking.attStatus,
            regulatory: regulatory.map(RegulatoryPayload.init),
            sdk: SDKInfo(),
            app: .current(),
            device: device,
            player: player,
            video: ContentPayload(content),
            section: VideoAds.sendable(section),
            sessionId: sessionId
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
    let isFullscreen: Bool
    /// Milliseconds in content time; 0 before the episode plays.
    let playhead: Int

    private enum CodingKeys: String, CodingKey {
        case width, height, playhead
        case isFullscreen = "fullscreen"
    }

    /// The key window's size, or the screen's, in points: width < height is portrait. `playhead` in
    /// seconds, as the SDK keeps it; the wire takes milliseconds.
    @MainActor
    static func make(playhead: TimeInterval) -> PlayerSnapshot {
        let screen = (Environment.keyWindow()?.bounds ?? UIScreen.main.bounds).size
        return PlayerSnapshot(width: Int(screen.width.rounded()), height: Int(screen.height.rounded()), isFullscreen: true,
                              playhead: Int((playhead * 1000).rounded()))
    }
}
