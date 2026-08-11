import SwiftUI

/// Fullscreen vertical feed of a story's episodes — swipe up/down to change episode.
struct StoryPlayerView: View {
    let story: Story

    @Environment(\.dismiss) private var dismiss
    @State private var currentEpisodeID: Episode.ID?

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
                            isActive: currentEpisodeID == episode.id
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
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.4), in: Circle())
        }
        .padding(.trailing, 16)
    }
}

#Preview {
    StoryPlayerView(story: Story.samples[0])
}
