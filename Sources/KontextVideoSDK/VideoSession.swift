import Foundation

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
    /// handle. Responses for a previous video are dropped once a new one
    /// is set.
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
        currentVideo = ads
        return ads
    }

    // MARK: - Internal

    func preload(_ ads: VideoAds, formats: [VideoAdFormat]) async -> [VideoAd] {
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
                sdk: SDKInfo.current
            ))
            if let newSessionId = response.sessionId {
                sessionId = newSessionId
            }
            guard currentVideo === ads else { return [] }
            let served = response.ads.filter { formats.contains($0.format) }
            log("/preload → \(served.count) ad(s) for \(ads.externalId)")
            return served
        } catch {
            emit(.error(VideoAdEvent.ErrorData(externalId: ads.externalId, message: "\(error)")))
            return []
        }
    }

    private func log(_ message: String) {
        print("[KontextVideoSDK] \(message)")
    }

    private func emit(_ event: VideoAdEvent) {
        options.onEvent?(event)
    }
}
