import SwiftUI

struct StoryCardView: View {
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(story.genre) · \(story.episodes.count) episodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: story.coverGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
            }
    }
}

#Preview {
    StoryCardView(story: Story.samples[0])
        .frame(width: 180)
        .padding()
}
