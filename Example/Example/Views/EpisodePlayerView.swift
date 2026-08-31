import AVFoundation
import KontextVideoSDK
import SwiftUI

/// A single fullscreen episode page: video + title overlay, tap to play/pause.
/// Drives the pause ads from the same place playback is controlled; the
/// feed owns the `VideoAds` handle (it also needs it for the swipe ad).
struct EpisodePlayerView: View {
    let story: Story
    let episode: Episode
    let isActive: Bool
    let ads: VideoAds?

    @State private var player: AVPlayer?
    @State private var isPaused = false
    @State private var playerLayerView = PlayerLayerUIView()
    @State private var timeObserver: Any?
    /// The time-observer closure is created once; it reads the live handle
    /// and active flag from here instead of capturing stale struct values.
    @State private var live = LiveState()

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player, layerView: playerLayerView)
            }
            if isPaused {
                Image(systemName: "play.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .contentShape(Rectangle())
        .onTapGesture(perform: togglePlayback)
        .overlay(alignment: .bottomLeading) {
            episodeInfo
        }
        .onAppear {
            let player = AVPlayer(url: episode.videoURL)
            player.actionAtItemEnd = .none
            self.player = player
            if isActive {
                player.play()
                startAutoPauseLoopIfRequested()
            }
            live.ads = ads
            live.isActive = isActive
            feedPlayhead(from: player)
        }
        .onChange(of: ads.map { ObjectIdentifier($0) }) { live.ads = ads }
        .onDisappear {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player?.pause()
            player = nil
        }
        .onChange(of: isActive) {
            live.isActive = isActive
            isPaused = false
            ads?.pause.hide()
            if isActive {
                player?.seek(to: .zero)
                player?.play()
            } else {
                player?.pause()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
        ) { notification in
            // Loop the episode while it stays on screen.
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else {
                return
            }
            player?.seek(to: .zero)
            player?.play()
        }
    }

    private var episodeInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(story.title)
                .font(.headline)
                .foregroundStyle(.white)
            Text("Episode \(episode.number) · \(episode.title)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// The overlay glue: the SDK gets the playhead 4× a second and calls
    /// back when a window opens or closes; showing stays this app's call.
    private func feedPlayhead(from player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { time in
            Task { @MainActor in
                guard let ads = live.ads, live.isActive else { return }
                ads.overlay.onWindowOpen = { _ in
                    // Player ignores the safe area: keep the banner clear
                    // of the status bar (top) and the episode title (bottom).
                    var style = OverlayAd.Style()
                    style.margins.top = 72
                    style.margins.bottom = 120
                    ads.overlay.show(in: playerLayerView, style: style)
                }
                ads.overlay.onWindowClose = { _ in ads.overlay.hide() }
                ads.overlay.playhead = CMTimeGetSeconds(time)
            }
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPaused = true
            live.ads?.overlay.hide()
            showPauseAd()
        } else {
            resume()
        }
    }

    private func showPauseAd() {
        // Read through `live` — long-lived closures (the auto-pause loop)
        // capture this struct before the handle exists.
        guard let ads = live.ads, ads.pause.isReady else { return }
        // The player view ignores the safe area, so its safe-area guide
        // is zero: push the banner below the status bar and back button.
        var style = PauseAd.Style()
        style.margins.top = 72
        ads.pause.show(in: playerLayerView, style: style)
    }

    private func resume() {
        live.ads?.pause.hide()
        live.ads?.overlay.hide()
        player?.play()
        isPaused = false
        // The shown ad is consumed; ask for the next one while the episode
        // keeps playing. The server answers with a new bidId (or noFill).
        if let ads = live.ads, !ads.pause.isReady {
            ads.load(formats: [.pause])
        }
    }

    /// Debug/CI hook: `SIMCTL_CHILD_AUTO_PAUSE_LOOP=1` pauses and resumes
    /// every 3 s (the ad shows at once and needs 1 s on screen to count as
    /// viewable) so the pause → ad → pings → resume → reload cycle can be
    /// observed from the console without touching the screen.
    private func startAutoPauseLoopIfRequested() {
        guard ProcessInfo.processInfo.environment["AUTO_PAUSE_LOOP"] != nil else { return }
        Task { @MainActor in
            while isActive, player != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                togglePlayback()
            }
        }
    }
}

/// AVPlayerLayer wrapper so the video fills the page. Uses an externally
/// owned `PlayerLayerUIView` so the same view can be handed to
/// `ads.pause.show(in:)`, which mounts the ad into it.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let layerView: PlayerLayerUIView

    func makeUIView(context: Context) -> PlayerLayerUIView {
        layerView.playerLayer.videoGravity = .resizeAspectFill
        layerView.playerLayer.player = player
        return layerView
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

@MainActor
final class LiveState {
    var ads: VideoAds?
    var isActive = false
}

final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
