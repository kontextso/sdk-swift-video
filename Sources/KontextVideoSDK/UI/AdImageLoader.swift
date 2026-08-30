import UIKit

/// Shared one-shot image loader for ad views. `onLoaded` runs on the main
/// thread once the image is set — that is the moment the impression fires.
enum AdImageLoader {
    @MainActor
    static func load(_ urlString: String, into imageView: UIImageView, onLoaded: @escaping @MainActor () -> Void) {
        guard let url = URL(string: urlString) else { return }
        Task { [weak imageView] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                guard let imageView else { return }
                imageView.image = image
                onLoaded()
            }
        }
    }
}
