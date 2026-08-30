import AVFoundation
import KontextVideoSDK
import SwiftUI

/// A single fullscreen episode page: video + title overlay, tap to play/pause.
/// Owns the episode's `VideoAds` handle and drives the pause ad from the
/// same place playback is controlled.
struct EpisodePlayerView: View {
    let story: Story
    let episode: Episode
    let isActive: Bool

    @State private var player: AVPlayer?
    @State private var isPaused = false
    @State private var playerLayerView = PlayerLayerUIView()
    @State private var ads: VideoAds?

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
                startVideo()
                player.play()
                startAutoPauseLoopIfRequested()
            }
        }
        .onDisappear {
            if let ads { Task { await ads.destroy() } }
            ads = nil
            player?.pause()
            player = nil
        }
        .onChange(of: isActive) {
            isPaused = false
            ads?.pauseOverlay.hide()
            ads?.pauseFullscreen.hide()
            if isActive {
                startVideo()
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

    private func startVideo() {
        let ads = Ads.session.setVideo(
            externalId: episode.id,
            title: "\(story.title) — Episode \(episode.number): \(episode.title)"
        )
        ads.load(formats: [.pauseOverlay, .pauseFullscreen])
        self.ads = ads
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPaused = true
            showPauseAd()
        } else {
            resume()
        }
    }

    /// Fullscreen wins when both are ready; otherwise the banner.
    private func showPauseAd() {
        guard let ads else { return }
        if ads.pauseFullscreen.isReady {
            ads.pauseFullscreen.show(in: playerLayerView) { resume() }
        } else if ads.pauseOverlay.isReady {
            // The player view ignores the safe area, so its safe-area guide
            // is zero: push the banner below the status bar and back button.
            var style = PauseOverlayAd.Style()
            style.margins.top = 72
            ads.pauseOverlay.show(in: playerLayerView, style: style)
        }
    }

    private func resume() {
        ads?.pauseOverlay.hide()
        ads?.pauseFullscreen.hide()
        player?.play()
        isPaused = false
        // The shown ad is consumed; ask for the next one while the episode
        // keeps playing. The server answers with a new bidId (or noFill).
        if let ads, !ads.pauseOverlay.isReady, !ads.pauseFullscreen.isReady {
            ads.load(formats: [.pauseOverlay, .pauseFullscreen])
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
/// `ads.pauseOverlay.show(in:)` / `ads.pauseFullscreen.show(in:)`, which mount the ad into it.
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

final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
