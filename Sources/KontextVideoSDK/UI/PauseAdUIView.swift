import UIKit

/// Pause ad, v1: the creative image as a banner pinned to the top or bottom
/// of the container. Tapping it opens the click-through URL. Nothing else is drawn —
/// the app keeps its own player chrome.
final class PauseAdUIView: UIView {
    private let creative: VideoAdCreative
    private let imageView = UIImageView()

    init(creative: VideoAdCreative) {
        self.creative = creative
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        AdImageLoader.load(creative.image.url, into: imageView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    /// Height for a given width, from the creative's declared image size.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard creative.image.w > 0, creative.image.h > 0 else { return width * 0.6 }
        return width * CGFloat(creative.image.h) / CGFloat(creative.image.w)
    }

    @objc private func didTap() {
        guard let url = URL(string: creative.cta.url) else { return }
        UIApplication.shared.open(url)
    }
}
