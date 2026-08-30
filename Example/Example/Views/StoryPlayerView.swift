import KontextVideoSDK
import SwiftUI

/// Fullscreen vertical feed of a story's episodes — swipe up/down to change episode.
///
/// The swipe ad is an interstitial: when the user swipes *forward* and the
/// episode they left has one ready, it is shown over the feed, scrolling is
/// held until the SDK says it is skippable, and the next episode starts
/// when the ad finishes or the user swipes it away. Once gone it is gone —
/// swiping back never brings it back.
struct StoryPlayerView: View {
    let story: Story

    @Environment(\.dismiss) private var dismiss
    @State private var currentEpisodeID: Episode.ID?
    /// The episode whose ads handle is current — lags `currentEpisodeID`
    /// while a swipe ad is on screen.
    @State private var activeEpisodeID: Episode.ID?
    @State private var swipeAdHost = SwipeAdHostUIView()
    @State private var isSwipeAdShown = false
    @State private var isSwipeAdSkippable = false
    @State private var ads: VideoAds?

    init(story: Story) {
        self.story = story
        _currentEpisodeID = State(initialValue: story.episodes.first?.id)
        _activeEpisodeID = State(initialValue: story.episodes.first?.id)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(story.episodes) { episode in
                        EpisodePlayerView(
                            story: story,
                            episode: episode,
                            isActive: activeEpisodeID == episode.id && !isSwipeAdShown,
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
            .scrollDisabled(isSwipeAdShown && !isSwipeAdSkippable)
        }
        .ignoresSafeArea()
        .background(.black)
        .overlay {
            if isSwipeAdShown {
                SwipeAdHostView(hostView: swipeAdHost)
                    .ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 40).onEnded { value in
                        // The user swiped the ad away — only allowed once skippable.
                        guard isSwipeAdSkippable, abs(value.translation.height) > 60 else { return }
                        ads?.swipe.hide()
                        finishSwipeAd()
                    })
            }
        }
        .overlay(alignment: .topLeading) {
            // The ad carries its own chrome (AD badge, Skip).
            if !isSwipeAdShown { backButton }
        }
        .statusBarHidden()
        .onAppear {
            if let id = currentEpisodeID { startEpisode(id) }
            startAutoSwipeIfRequested()
        }
        .onDisappear {
            ads?.swipe.hide()
        }
        .onChange(of: currentEpisodeID) { _, newID in
            guard let newID, newID != activeEpisodeID, !isSwipeAdShown else { return }
            episodeChanged(to: newID)
        }
    }

    /// The user swiped to `newID`. Moving forward out of an episode with a
    /// swipe ad ready shows it first; the new episode starts when the ad is
    /// done. Swiping back never shows an ad.
    private func episodeChanged(to newID: Episode.ID) {
        if let leaving = activeEpisodeID, isForward(from: leaving, to: newID),
           let ads, ads.swipe.isReady {
            isSwipeAdSkippable = false
            isSwipeAdShown = true
            ads.swipe.show(
                in: swipeAdHost,
                onSkippable: { isSwipeAdSkippable = true },
                onFinished: { finishSwipeAd() }
            )
        } else {
            startEpisode(newID)
        }
    }

    private func isForward(from: Episode.ID, to: Episode.ID) -> Bool {
        guard let a = story.episodes.firstIndex(where: { $0.id == from }),
              let b = story.episodes.firstIndex(where: { $0.id == to }) else { return false }
        return b > a
    }

    private func finishSwipeAd() {
        isSwipeAdShown = false
        isSwipeAdSkippable = false
        if let id = currentEpisodeID { startEpisode(id) }
    }

    /// Makes `id` the current video, loaded with every format so the swipe
    /// ad is ready before the user leaves it.
    private func startEpisode(_ id: Episode.ID) {
        guard let episode = story.episodes.first(where: { $0.id == id }) else { return }
        let handle = Ads.session.setVideo(
            externalId: episode.id,
            title: "\(story.title) — Episode \(episode.number): \(episode.title)"
        )
        handle.load(formats: [.pauseOverlay, .pauseFullscreen, .swipe])
        ads = handle
        activeEpisodeID = id
    }

    /// Debug/CI hook: `SIMCTL_CHILD_AUTO_SWIPE=1` swipes forward after 4 s
    /// (shows the swipe ad), then back after 20 s (no ad on the way back).
    private func startAutoSwipeIfRequested() {
        guard ProcessInfo.processInfo.environment["AUTO_SWIPE"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            swipe(by: 1)
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            swipe(by: -1)
        }
    }

    private func swipe(by delta: Int) {
        guard let current = currentEpisodeID,
              let index = story.episodes.firstIndex(where: { $0.id == current }),
              story.episodes.indices.contains(index + delta) else { return }
        withAnimation { currentEpisodeID = story.episodes[index + delta].id }
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

/// Plain UIView the SDK mounts the swipe ad into.
final class SwipeAdHostUIView: UIView {}

private struct SwipeAdHostView: UIViewRepresentable {
    let hostView: SwipeAdHostUIView

    func makeUIView(context: Context) -> SwipeAdHostUIView {
        hostView.backgroundColor = .black
        return hostView
    }

    func updateUIView(_ uiView: SwipeAdHostUIView, context: Context) {}
}

#Preview {
    StoryPlayerView(story: Story.samples[0])
}
