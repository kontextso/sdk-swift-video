import SwiftUI

/// Three videos, one per ad format. Tapping one opens the full-screen player.
struct HomeView: View {
    @State private var selected: Video?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Video.all) { video in
                        Button {
                            selected = video
                        } label: {
                            card(video)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Kontext Video")
        }
        .fullScreenCover(item: $selected) { video in
            PlayerScreen(video: video)
        }
        .onAppear {
            // Hands-free: `SIMCTL_CHILD_KONTEXT_OPEN=linear xcrun simctl launch ...` opens that video at once.
            if let id = ProcessInfo.processInfo.environment["KONTEXT_OPEN"] {
                selected = Video.all.first { $0.format.rawValue == id }
            }
        }
    }

    private func card(_ video: Video) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: video.cover, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 84, height: 112)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.9))
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.headline)
                Text(video.caption).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
