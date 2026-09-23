import KontextVideoSDK
import SwiftUI

/// Fullscreen vertical feed of a story's episodes — swipe up/down to change episode.
/// Each episode gets its own `VideoAds` handle, loaded with every format
/// the moment it becomes current.
struct StoryPlayerView: View {
    let story: Story

    @Environment(\.dismiss) private var dismiss
    @State private var currentEpisodeID: Episode.ID?
    /// The episode whose ads handle is current. `scrollPosition` can
    /// re-report the same id (e.g. when the interstitial is presented over
    /// the feed), and re-creating the handle would destroy the ad on screen.
    @State private var activeEpisodeID: Episode.ID?
    @State private var ads: VideoAds?

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
                            ads: activeEpisodeID == episode.id ? ads : nil
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
            ads?.interstitial.hide()
        }
        .onChange(of: currentEpisodeID) { _, newID in
            guard let newID, newID != activeEpisodeID else { return }
            startEpisode(newID)
        }
    }

    /// Makes `id` the current video, loaded with every format.
    private func startEpisode(_ id: Episode.ID) {
        guard let episode = story.episodes.first(where: { $0.id == id }) else { return }
        let handle = Ads.session.setVideo(
            id: episode.id,
            title: episode.title,
            duration: 20.5,
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
        ads = handle
        activeEpisodeID = id
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

#Preview {
    StoryPlayerView(story: Story.samples[0])
}
