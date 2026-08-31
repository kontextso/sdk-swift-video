import Foundation
import KontextKit
import UIKit

/// One instance per app user. Owns the connection to the ad server and the
/// viewing-session ID.
///
/// Lifecycle:
/// 1. Create via ``KontextVideo/createSession(_:)``.
/// 2. Call ``setVideo(id:title:description:duration:language:episodeNumber:series:)`` every time a new
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

    /// Persistent per-install id (KontextKit, UUID v7), sent on `/init` and
    /// every `/preload`; the publisher never manages it.
    let installId: String

    /// The handle returned by the latest `setVideo`.
    public private(set) var currentVideo: VideoAds?

    /// `false` once `/init` reports the session permanently disabled;
    /// `load` becomes a no-op.
    public private(set) var isEnabled = true

    private let adsService: AdsService
    private let initService: InitService
    private var preloadTimeout: TimeInterval = Constants.defaultPreloadTimeout

    init(options: VideoSessionOptions) {
        self.options = options
        self.installId = InstallIdProvider.getOrCreate()
        self.adsService = AdsService(adServerURL: options.adServerURL)
        self.initService = InitService(adServerURL: options.adServerURL)
        // Fire /init in the background: reports SKAdNetwork ids and lets the
        // server disable the session / override the preload timeout. Never
        // blocks ad requests.
        Task { await runInit() }
    }

    private func runInit() async {
        let response = await initService.fetchInit(InitService.InitRequest(
            publisherToken: options.publisherToken,
            userId: options.userId,
            installId: installId,
            sdk: SDKInfo.current,
            app: InitService.InitRequest.App(
                bundleId: AppInfoProvider.collect().bundleId,
                version: AppInfoProvider.collect().version
            ),
            skan: InitService.InitRequest.Skan(items: SKAdNetworkIdsProvider.collect())
        ))
        guard let response else { return }
        isEnabled = response.enabled
        if let ms = response.preloadTimeoutMs {
            preloadTimeout = TimeInterval(ms) / 1000
        }
        if !isEnabled {
            log("session disabled by /init")
        }
    }

    /// Makes the video with `id` current and returns its ads handle.
    /// Does not request anything — call ``VideoAds/load(formats:)`` on the
    /// handle. The previous video's handle is destroyed in the background
    /// (see ``VideoAds/destroy()``).
    ///
    /// - Parameters:
    ///   - id: The publisher's unique ID for this video — any scheme
    ///     (`"100001-6"`, a UUID…), as long as it identifies the video.
    ///   - title: Optional if the video was uploaded via the API. Otherwise
    ///     it is contextual signal, like `description`.
    ///   - duration: Video length in seconds, when known. Lets the server
    ///     place overlay windows for videos it has never analyzed.
    ///   - language: The audio/subtitle track being played (ISO 639) — ad
    ///     copy follows it, not the app locale.
    ///   - episodeNumber: Position within `series`, when applicable.
    ///   - series: Series-level metadata; for short drama this is where
    ///     the synopsis, keywords, and content rating live.
    public func setVideo(
        id: String,
        title: String? = nil,
        description: String? = nil,
        duration: TimeInterval? = nil,
        language: String? = nil,
        episodeNumber: Int? = nil,
        series: VideoSeries? = nil
    ) -> VideoAds {
        let ads = VideoAds(
            videoId: id,
            title: title,
            description: description,
            duration: duration,
            language: language,
            episodeNumber: episodeNumber,
            series: series,
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
        let results: [AdsService.PreloadResponse.FormatResult]?
        let noFillReason: String?
        /// `false` when the request failed — the caller emits no `.loaded`.
        let succeeded: Bool
    }

    func preload(_ ads: VideoAds, formats: [VideoAdFormat], playerSize: CGSize?) async -> PreloadOutcome {
        do {
            let response = try await adsService.preload(AdsService.PreloadRequest(
                publisherToken: options.publisherToken,
                userId: options.userId,
                userEmail: options.userEmail,
                sessionId: sessionId,
                installId: installId,
                id: ads.videoId,
                title: ads.title,
                description: ads.description,
                durationMs: ads.duration.map { Int($0 * 1000) },
                language: ads.language,
                episodeNumber: ads.episodeNumber,
                series: ads.series,
                formats: formats,
                context: playerSize.map { AdsService.PreloadRequest.Context(playerWidth: Int($0.width), playerHeight: Int($0.height)) },
                sdk: SDKInfo.current
            ), timeout: preloadTimeout)
            if let newSessionId = response.sessionId {
                sessionId = newSessionId
            }
            guard currentVideo === ads else { return PreloadOutcome(ads: [], results: nil, noFillReason: nil, succeeded: false) }
            let served = response.ads.filter { formats.contains($0.format) }
            log("/instream/preload → \(served.count) ad(s) for \(ads.videoId)\(response.noFillReason.map { " (\($0))" } ?? "")")
            return PreloadOutcome(ads: served, results: response.results, noFillReason: response.noFillReason, succeeded: true)
        } catch is CancellationError {
            return PreloadOutcome(ads: [], results: nil, noFillReason: nil, succeeded: false)
        } catch let error as URLError where error.code == .cancelled {
            return PreloadOutcome(ads: [], results: nil, noFillReason: nil, succeeded: false)
        } catch {
            emit(.error(VideoAdEvent.ErrorData(videoId: ads.videoId, message: "\(error)")))
            return PreloadOutcome(ads: [], results: nil, noFillReason: nil, succeeded: false)
        }
    }

    private func log(_ message: String) {
        print("[KontextVideoSDK] \(message)")
    }

    private func emit(_ event: VideoAdEvent) {
        options.onEvent?(event)
    }
}
