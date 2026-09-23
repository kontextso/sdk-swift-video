import KontextVideoSDK
import SwiftUI

/// Fullscreen vertical feed of a story's episodes — swipe up/down to change episode.
/// Each episode gets its own `VideoAds` handle. The handle for the *next*
/// episode is created and loaded while the current one plays, so its ads
/// are ready the moment the viewer swipes; the previous episode's handle
/// is destroyed when the viewer moves on.
struct StoryPlayerView: View {
    let story: Story

    @Environment(\.dismiss) private var dismiss
    @State private var currentEpisodeID: Episode.ID?
    /// The episode whose handle drives the player. `scrollPosition` can
    /// re-report the same id (e.g. when the interstitial is presented over
    /// the feed); this guard keeps that from re-creating the handle and
    /// destroying the ad on screen.
    @State private var activeEpisodeID: Episode.ID?
    /// Live handles: the active episode's and the next one's.
    @State private var handles: [Episode.ID: VideoAds] = [:]

    init(story: Story) {
        self.story = story
        _currentEpisodeID = State(initialValue: story.episodes.first?.id)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(story.episodes) { episode in
                        EpisodePlayerView(
                            story: story,
                            episode: episode,
                            isActive: activeEpisodeID == episode.id,
                            ads: activeEpisodeID == episode.id ? handles[episode.id] : nil
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .id(episode.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $currentEpisodeID)
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
        }
        .ignoresSafeArea()
        .background(.black)
        .overlay(alignment: .topLeading) {
            backButton
        }
        .statusBarHidden()
        .onAppear {
            if let id = currentEpisodeID { startEpisode(id) }
        }
        .onDisappear {
            activeEpisodeID.flatMap { handles[$0] }?.interstitial.hide()
        }
        .onChange(of: currentEpisodeID) { _, newID in
            guard let newID, newID != activeEpisodeID else { return }
            startEpisode(newID)
        }
    }

    /// Makes `id` the active episode: its handle (usually prepared while
    /// the previous episode played) drives the player, the next episode's
    /// is prepared now, and every other handle is released.
    private func startEpisode(_ id: Episode.ID) {
        guard let index = story.episodes.firstIndex(where: { $0.id == id }) else { return }
        let keep = [story.episodes[index], story.episodes[safe: index + 1]].compactMap { $0 }
        for episode in keep where handles[episode.id] == nil {
            handles[episode.id] = prepareAds(for: episode)
        }
        for (episodeID, handle) in handles where !keep.contains(where: { $0.id == episodeID }) {
            handles[episodeID] = nil
            Task { await handle.destroy() }
        }
        activeEpisodeID = id
    }

    private func prepareAds(for episode: Episode) -> VideoAds {
        let handle = Ads.session.createAds(
            videoId: episode.id,
            title: episode.title,
            durationMs: 20_500,
            language: "en",
            episodeNumber: episode.number,
            series: VideoSeries(
                id: story.id,
                title: story.title,
                description: "A short-drama series from the demo catalog.",
                keywords: [story.genre.lowercased()],
                episodeCount: story.episodes.count
            )
        )
        handle.load(formats: [.pause, .interstitial, .overlay])
        return handle
    }

    // A back chevron, not an X — the X is reserved for closing ads, and two
    // different Xs on screen would be confusing.
    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.4), in: Circle())
        }
        .padding(.leading, 16)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    StoryPlayerView(story: Story.samples[0])
}
