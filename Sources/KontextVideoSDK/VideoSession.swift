import Foundation
import UIKit

/// One instance per app user. Owns the connection to the ad server and the
/// viewing-session ID.
///
/// Lifecycle:
/// 1. Create via ``KontextVideo/createSession(_:)``.
/// 2. Call ``setVideo(externalId:title:description:)`` every time a new
///    video becomes current. It returns the ``VideoAds`` handle for that
///    video; call ``VideoAds/load(formats:)`` on it to request ads.
/// 3. Drive the ads from the handle — the SDK never observes the player;
///    the app tells it when to show, hide, and load again.
@MainActor
public final class VideoSession {
    public let options: VideoSessionOptions

    /// Viewing-session ID assigned by the server on the first preload
    /// response; sent with every subsequent request.
    private(set) var sessionId: String?

    /// The handle returned by the latest ``setVideo(externalId:title:description:)``.
    public private(set) var currentVideo: VideoAds?

    private let adsService: AdsService

    init(options: VideoSessionOptions) {
        self.options = options
        self.adsService = AdsService(adServerURL: options.adServerURL)
    }

    /// Makes `externalId` the current video and returns its ads handle.
    /// Does not request anything — call ``VideoAds/load(formats:)`` on the
    /// handle. The previous video's handle is destroyed in the background
    /// (see ``VideoAds/destroy()``).
    ///
    /// - Parameters:
    ///   - externalId: The publisher's own video ID.
    ///   - title: Optional if the video was uploaded via the API. Otherwise
    ///     it is the main content context the server gets.
    ///   - description: Same as `title`.
    public func setVideo(
        externalId: String,
        title: String? = nil,
        description: String? = nil
    ) -> VideoAds {
        let ads = VideoAds(
            externalId: externalId,
            title: title,
            description: description,
            session: self,
            emit: { [weak self] in self?.emit($0) }
        )
        if let previous = currentVideo {
            Task { await previous.destroy() }
        }
        currentVideo = ads
        return ads
    }

    // MARK: - Internal

    struct PreloadOutcome {
        let ads: [VideoAd]
        let noFillReason: String?
        /// `false` when the request failed — the caller emits no `noFill`.
        let succeeded: Bool
    }

    func preload(_ ads: VideoAds, formats: [VideoAdFormat], playerSize: CGSize?) async -> PreloadOutcome {
        do {
            let response = try await adsService.preload(AdsService.PreloadRequest(
                publisherToken: options.publisherToken,
                userId: options.userId,
                userEmail: options.userEmail,
                sessionId: sessionId,
                externalId: ads.externalId,
                title: ads.title,
                description: ads.description,
                formats: formats,
                context: playerSize.map { AdsService.PreloadRequest.Context(playerWidth: Int($0.width), playerHeight: Int($0.height)) },
                sdk: SDKInfo.current
            ))
            if let newSessionId = response.sessionId {
                sessionId = newSessionId
            }
            guard currentVideo === ads else { return PreloadOutcome(ads: [], noFillReason: nil, succeeded: false) }
            let served = response.ads.filter { formats.contains($0.format) }
            log("/instream/preload → \(served.count) ad(s) for \(ads.externalId)\(response.noFillReason.map { " (\($0))" } ?? "")")
            return PreloadOutcome(ads: served, noFillReason: response.noFillReason, succeeded: true)
        } catch {
            emit(.error(VideoAdEvent.ErrorData(externalId: ads.externalId, message: "\(error)")))
            return PreloadOutcome(ads: [], noFillReason: nil, succeeded: false)
        }
    }

    private func log(_ message: String) {
        print("[KontextVideoSDK] \(message)")
    }

    private func emit(_ event: VideoAdEvent) {
        options.onEvent?(event)
    }
}
