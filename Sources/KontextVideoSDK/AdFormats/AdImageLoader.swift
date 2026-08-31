import UIKit

/// Shared one-shot image loader for ad views. `onLoaded` runs on the main
/// thread once the image is set — that is the moment the impression fires.
/// `onFailed` runs when the URL is bad or the download/decode fails, so the
/// caller can surface it instead of leaving a blank box on screen.
enum AdImageLoader {
    @MainActor
    static func load(
        _ urlString: String,
        into imageView: UIImageView,
        onLoaded: @escaping @MainActor () -> Void,
        onFailed: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        guard let url = URL(string: urlString) else {
            onFailed("invalid image url: \(urlString)")
            return
        }
        Task { [weak imageView] in
            let image: UIImage?
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    await MainActor.run { onFailed("image http \(http.statusCode)") }
                    return
                }
                image = UIImage(data: data)
            } catch {
                await MainActor.run { onFailed("image download failed: \(error.localizedDescription)") }
                return
            }
            await MainActor.run {
                guard let imageView else { return }
                guard let image else { onFailed("image data is not a decodable image"); return }
                imageView.image = image
                onLoaded()
            }
        }
    }
}
