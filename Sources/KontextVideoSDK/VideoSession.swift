import AVFoundation
import UIKit

/// One instance per app user. Owns the connection to the ad server,
/// the attached player, and the per-video ad lifecycle.
///
/// Lifecycle:
/// 1. Create via ``KontextVideo/createSession(_:)``.
/// 2. Attach the publisher's player with ``attachPlayer(playerView:player:)``
///    so the SDK can render ads over it (overlay, pause ad) and observe
///    playback state.
/// 3. Call ``startVideo(externalId:title:description:)`` every time a new
///    video starts loading. This preloads ads for all enabled formats and
///    returns a ``VideoAds`` handle for that video.
@MainActor
public final class VideoSession {
    public let options: VideoSessionOptions

    /// Persistent install ID, generated on first launch.
    let installId: String

    /// Viewing-session ID assigned by the server on the first preload
    /// response. Empty until then; sent with every subsequent request.
    private(set) var sessionId: String = ""

    private weak var playerView: UIView?
    private weak var player: AVPlayer?
    private let preloadService: PreloadService

    init(options: VideoSessionOptions) {
        self.options = options
        self.installId = InstallID.current
        self.preloadService = PreloadService(adServerURL: options.adServerURL)
    }

    /// Attaches the publisher's player so the SDK can render ads over it
    /// (overlay, pause ad) and react to playback state (pause detection).
    ///
    /// Player integrations differ per publisher; this AVPlayer-based entry
    /// point is the baseline and will grow richer variants as design
    /// partners need them.
    public func attachPlayer(playerView: UIView, player: AVPlayer) {
        self.playerView = playerView
        self.player = player
        // TODO: observe player state (pause/resume/end) to drive pause ads.
    }

    /// Tells the SDK a new video is loading. Fires a preload for all enabled
    /// formats and returns the handle holding the ads prepared for this
    /// video (not the video itself).
    ///
    /// Overlay and pause ads are shown automatically via the attached
    /// player. The swipe banner must be triggered by the app via
    /// ``VideoAds/showSwipeBanner()``.
    ///
    /// - Parameters:
    ///   - externalId: The publisher's own video ID. When the publisher's
    ///     videos were previously uploaded via the Kontext API, this is the
    ///     `external_id` used there.
    ///   - title: Optional if the video was uploaded via the API. Otherwise
    ///     it is the main content context the server gets.
    ///   - description: Same as `title`.
    public func startVideo(
        externalId: String,
        title: String? = nil,
        description: String? = nil
    ) -> VideoAds {
        let ads = VideoAds(externalId: externalId, session: self)
        Task {
            await preload(for: ads, title: title, description: description)
        }
        return ads
    }

    // MARK: - Internal

    private func preload(for ads: VideoAds, title: String?, description: String?) async {
        do {
            let response = try await preloadService.preload(
                PreloadRequest(
                    publisherToken: options.publisherToken,
                    userId: options.userId,
                    userEmail: options.userEmail,
                    installId: installId,
                    sessionId: sessionId,
                    externalId: ads.externalId,
                    title: title,
                    description: description,
                    enabledFormats: options.enabledFormats,
                    sdk: SDKInfo.current
                )
            )
            if let newSessionId = response.sessionId, !newSessionId.isEmpty {
                sessionId = newSessionId
            }
            ads.apply(response)
            for ad in response.ads {
                emit(.filled(VideoAdEvent.AdData(format: ad.format, externalId: ads.externalId)))
            }
            let filledFormats = Set(response.ads.map(\.format))
            for format in options.enabledFormats where !filledFormats.contains(format) {
                emit(.noFill(VideoAdEvent.AdData(format: format, externalId: ads.externalId)))
            }
        } catch {
            emit(.error(VideoAdEvent.ErrorData(externalId: ads.externalId, message: "\(error)")))
        }
    }

    func emit(_ event: VideoAdEvent) {
        options.onEvent?(event)
    }
}
