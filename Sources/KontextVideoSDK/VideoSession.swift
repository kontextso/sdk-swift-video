import Foundation

/// One instance per app user. Owns the connection to the ad server and the
/// viewing-session ID.
///
/// Lifecycle:
/// 1. Create via ``KontextVideo/createSession(_:)``.
/// 2. Call ``startVideo(externalId:title:description:)`` every time a new
///    video starts loading. This preloads the ads and returns a
///    ``VideoAds`` handle for that video.
/// 3. Drive the ads from the handle — the SDK never observes the player;
///    the app tells it when to show and hide.
@MainActor
public final class VideoSession {
    public let options: VideoSessionOptions

    /// Viewing-session ID assigned by the server on the first preload
    /// response; sent with every subsequent request.
    private(set) var sessionId: String?

    private let adsService: AdsService

    init(options: VideoSessionOptions) {
        self.options = options
        self.adsService = AdsService(adServerURL: options.adServerURL)
    }

    /// Tells the SDK a new video is loading. Fires `/preload` for the whole
    /// video and returns the handle holding the ads prepared for this video
    /// (not the video itself).
    ///
    /// - Parameters:
    ///   - externalId: The publisher's own video ID.
    ///   - title: Optional if the video was uploaded via the API. Otherwise
    ///     it is the main content context the server gets.
    ///   - description: Same as `title`.
    public func startVideo(
        externalId: String,
        title: String? = nil,
        description: String? = nil
    ) -> VideoAds {
        let ads = VideoAds(externalId: externalId, emit: { [weak self] in self?.emit($0) })
        Task {
            await preload(ads, title: title, description: description)
        }
        return ads
    }

    // MARK: - Internal

    private func preload(_ ads: VideoAds, title: String?, description: String?) async {
        do {
            let response = try await adsService.preload(AdsService.PreloadRequest(
                publisherToken: options.publisherToken,
                userId: options.userId,
                userEmail: options.userEmail,
                sessionId: sessionId,
                externalId: ads.externalId,
                title: title,
                description: description,
                enabledFormats: options.enabledFormats,
                sdk: SDKInfo.current
            ))
            if let newSessionId = response.sessionId {
                sessionId = newSessionId
            }
            let enabled = response.ads.filter { options.enabledFormats.contains($0.format) }
            ads.apply(enabled)
            log("/preload → \(enabled.count) ad(s) for \(ads.externalId)")
            if enabled.isEmpty {
                emit(.noFill(VideoAdEvent.AdData(format: .pauseAd, externalId: ads.externalId)))
            }
            for ad in enabled {
                emit(.filled(VideoAdEvent.AdData(format: ad.format, externalId: ads.externalId)))
            }
        } catch {
            emit(.error(VideoAdEvent.ErrorData(externalId: ads.externalId, message: "\(error)")))
        }
    }

    private func log(_ message: String) {
        print("[KontextVideoSDK] \(message)")
    }

    private func emit(_ event: VideoAdEvent) {
        options.onEvent?(event)
    }
}
