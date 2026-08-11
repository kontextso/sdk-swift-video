import AVFoundation
import KontextVideoSDK
import SwiftUI

/// A single fullscreen episode page: video + title overlay, tap to play/pause.
struct EpisodePlayerView: View {
    let story: Story
    let episode: Episode
    let isActive: Bool

    @State private var player: AVPlayer?
    @State private var isPaused = false
    @State private var playerLayerView = PlayerLayerUIView()

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
                attachToAdsSession()
                player.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onChange(of: isActive) {
            isPaused = false
            if isActive {
                attachToAdsSession()
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

    private func attachToAdsSession() {
        guard let player else { return }
        Ads.session.attachPlayer(playerView: playerLayerView, player: player)
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPaused = true
        } else {
            player.play()
            isPaused = false
        }
    }
}

/// AVPlayerLayer wrapper so the video fills the page. Uses an externally
/// owned `PlayerLayerUIView` so the view can also be handed to the ads
/// session (`attachPlayer`), which mounts ad overlays into it.
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
