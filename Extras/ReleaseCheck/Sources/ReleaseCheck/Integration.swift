import AVFoundation
import KontextVideoSDK
import UIKit

/// The integration guide's calls, compiled against the released package: a public API the release lost or
/// renamed fails this build. Never run.
@MainActor
final class EpisodeScreen: UIViewController, VideoAdDelegate {
    private let player = AVPlayer()
    private var ads: VideoAds?
    private var overlayAd: VideoAd?

    static func start() async {
        let configuration = KontextVideo.Configuration(publisherToken: "<your-publisher-token>")
        _ = await KontextVideo.shared.initialize(with: configuration)
    }

    func prepare() async {
        let content = KontextVideo.Content(
            id: "episode-1234",
            language: "en",
            title: "Episode 1",
            duration: 93,
            genre: "romance",
            series: .init(id: "series-42", title: "Series", episodeCount: 6)
        )
        let ads = VideoAds(content: content, labels: ["stage": "first_episode"])
        ads.track(player)
        self.ads = ads
        do {
            let ad = try await ads.format(.overlay)
            print(ad.id, ad.format, ad.price, ad.duration ?? 0, ad.isReady)
            try await ad.load()
            ad.delegate = self
            overlayAd = ad
        } catch let error as VideoAdError {
            print(error)
        } catch {
            print(error)
        }
    }

    func showOverlay() {
        do {
            try overlayAd?.show(in: view, insets: UIEdgeInsets(top: 0, left: 0, bottom: 80, right: 0))
        } catch {
            try? overlayAd?.reject()
        }
    }

    func showLinear(_ ad: VideoAd) {
        try? ad.show(from: self)
    }

    func leave() {
        try? overlayAd?.dismiss()
        ads?.destroy()
    }

    func videoAdDidRecordImpression(_ ad: VideoAd) {}

    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {
        print(click.area)
    }

    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {}

    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        if reason == .resumed { player.play() }
    }
}
