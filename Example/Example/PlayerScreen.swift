import AVFoundation
import KontextVideoSDK
import SwiftUI
import UIKit

/// The full-screen player. The content plays in `playback.playerView`. Overlay and pause ads go into
/// `playback.adArea`, a transparent view over the video, shown with a bottom inset as tall as the episode's
/// title, so the ad never covers it; the SDK presents a linear ad over the screen.
struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: Playback

    init(video: Video) {
        _playback = StateObject(wrappedValue: Playback(video: video))
    }

    var body: some View {
        ZStack {
            PlayerView(view: playback.playerView)
                .ignoresSafeArea()
            if playback.isPaused {
                Image(systemName: "play.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.8))
            }
            ZStack(alignment: .bottomLeading) {
                // Where the SDK puts overlay and pause ads: the whole player area. `show(in:insets:)` keeps the
                // ad above the title, with the title's height as the bottom inset.
                AdAreaHost(view: playback.adArea)
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.video.title).font(.headline).foregroundStyle(.white)
                    Text(playback.status).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .background(GeometryReader { proxy in Color.clear.preference(key: TitleHeight.self, value: proxy.size.height) })
            }
            .onPreferenceChange(TitleHeight.self) { height in
                Task { @MainActor in playback.adInsets = UIEdgeInsets(top: 0, left: 0, bottom: height + 12, right: 0) }
            }
        }
        .background(.black)
        .contentShape(Rectangle())
        .onTapGesture { playback.toggle() }
        .overlay(alignment: .topLeading) {
            Button {
                playback.stop()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(16)
        }
        .statusBarHidden()
        // Not onDisappear: the linear ad's full-screen presentation covers this view, and SwiftUI
        // reports that as a disappearance too.
        .onAppear { playback.start() }
    }
}

/// The app side of one video: its player, its `VideoAds`, and the one ad the demo shows.
@MainActor
final class Playback: ObservableObject {
    @Published private(set) var status = "preparing the ad"
    @Published private(set) var isPaused = false

    let video: Video
    let playerView = PlayerLayerView()
    /// Where overlay and pause ads go: the whole player area.
    let adArea = AdAreaView()
    /// Keeps an overlay or pause ad above the title: the title's height, set by the screen.
    var adInsets = UIEdgeInsets.zero
    private let player: AVPlayer
    private let ads: VideoAds
    private var ad: VideoAd?
    private var loop: (any NSObjectProtocol)?
    private var started = false

    init(video: Video) {
        self.video = video
        player = AVPlayer(url: video.url)
        player.actionAtItemEnd = .none
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspectFill
        // Creating it sends nothing; the request goes out in prepare(). The SDK reads the playhead from the player.
        ads = VideoAds(content: .init(id: video.id, language: "en", title: video.title, genre: "romance"))
        ads.trackPlayhead(of: player)
    }

    /// The content starts and loops, the ad is prepared, and after 3 s a linear ad or an overlay shows; a pause
    /// ad waits for the viewer's tap. Once: SwiftUI calls `onAppear` again when the linear ad's presentation is
    /// dismissed.
    func start() {
        guard !started else { return }
        started = true
        player.play()
        loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        Task {
            await prepare()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            moment()
        }
    }

    /// Leaving the screen: the content stops and every ad of this video ends; the server hears of the unused ones.
    func stop() {
        player.pause()
        if let loop { NotificationCenter.default.removeObserver(loop) }
        ads.destroy()
    }

    /// Tap: pause, and with a pause ad ready, show it; tap again to resume.
    func toggle() {
        if isPaused { resume() } else { pause() }
    }

    /// `format` then `load`: the creative is rendered before the moment, so `show` is instant.
    private func prepare() async {
        do {
            let ad = try await ads.format(video.format)
            try await ad.load()
            ad.delegate = self
            self.ad = ad
            status = "\(video.format) ad ready, \(ad.price.value) \(ad.price.currency) CPM"
        } catch {
            status = "no \(video.format) ad: \(error)"
        }
    }

    private func moment() {
        switch video.format {
        case .linear: showLinear()
        case .overlay: showInPlayer()      // ends by itself after its duration
        case .pause: break                 // the viewer pauses; nothing happens on its own
        }
    }

    private func pause() {
        player.pause()
        isPaused = true
        if video.format == .pause { showInPlayer() }
    }

    private func resume() {
        if video.format == .pause {
            try? ad?.dismiss()
            Task { await prepare() }       // the next pause gets its own ad
        }
        player.play()
        isPaused = false
    }

    private func showInPlayer() {
        guard let ad, ad.isReady else { return }
        do {
            try ad.show(in: adArea, insets: adInsets)
        } catch {
            status = "show: \(error)"
        }
    }

    /// The SDK presents the linear ad from the top of the key window; the content pauses here and resumes in didEnd.
    private func showLinear() {
        guard let ad, ad.isReady else { return }
        player.pause()
        do {
            try ad.show()
        } catch {
            player.play()                  // never started: undo here, no delegate call follows
            status = "show: \(error)"
        }
    }
}

extension Playback: VideoAdDelegate {
    func videoAdDidRecordImpression(_ ad: VideoAd) {
        status = "\(ad.format) ad: impression"
    }

    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {
        status = "\(ad.format) ad: click (\(click.area))"
    }

    func videoAd(_ ad: VideoAd, didFail error: VideoAdError) {
        status = "\(ad.format) ad failed: \(error)"
    }

    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        status = "\(ad.format) ad ended: \(reason)"
        if ad === self.ad { self.ad = nil }
        switch ad.format {
        case .linear:
            player.play()                  // every way it ends lands here
        case .pause:
            if reason == .resumed { resume() }   // the viewer tapped Resume on the ad itself
        case .overlay:
            break
        }
    }
}

/// The player's view: an `AVPlayerLayer`. The SDK adds ad views into it.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        view.backgroundColor = .black
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// The height of the title block at the bottom of the screen, for the ad's bottom inset.
private struct TitleHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A transparent area that holds an overlay or pause ad. Taps outside the ad go through to the player.
final class AdAreaView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

struct AdAreaHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
