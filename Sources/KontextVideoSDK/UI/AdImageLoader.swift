import UIKit

/// Shared one-shot image loader for ad views.
enum AdImageLoader {
    @MainActor
    static func load(_ urlString: String, into imageView: UIImageView) {
        guard let url = URL(string: urlString) else { return }
        Task { [weak imageView] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            imageView?.image = UIImage(data: data)
        }
    }
}
