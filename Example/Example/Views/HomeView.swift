import SwiftUI

struct HomeView: View {
    @State private var selectedStory: Story?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Story.samples) { story in
                        Button {
                            selectedStory = story
                        } label: {
                            StoryCardView(story: story)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Kontext Drama")
            .background(Color(.systemGroupedBackground))
        }
        .fullScreenCover(item: $selectedStory) { story in
            StoryPlayerView(story: story)
        }
        .onAppear {
            // Debug/CI hook: jump straight into the player, e.g.
            // SIMCTL_CHILD_AUTO_OPEN_STORY=1 xcrun simctl launch ...
            if ProcessInfo.processInfo.environment["AUTO_OPEN_STORY"] != nil {
                selectedStory = Story.samples.first
            }
        }
    }
}

#Preview {
    HomeView()
}
