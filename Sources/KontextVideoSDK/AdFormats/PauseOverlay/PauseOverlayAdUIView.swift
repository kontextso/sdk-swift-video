import UIKit

/// The creative image as a rounded banner styled by `PauseOverlayAd.Style`.
/// Tapping it opens the click-through URL.
final class PauseOverlayAdUIView: UIView {
    private let ad: VideoAd
    private let style: PauseOverlayAd.Style
    private let imageView = UIImageView()

    var onClick: (() -> Void)?
    var onImageLoaded: (() -> Void)?

    init(ad: VideoAd, style: PauseOverlayAd.Style) {
        self.ad = ad
        self.style = style
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
        imageView.layer.cornerRadius = style.cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = style.placeholderColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if let image = ad.creative.image {
            AdImageLoader.load(image.url, into: imageView) { [weak self] in self?.onImageLoaded?() }
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    /// Height for a given width, from the creative's declared image size.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let image = ad.creative.image, image.w > 0, image.h > 0 else { return width * 0.6 }
        return width * CGFloat(image.h) / CGFloat(image.w)
    }

    @objc private func didTap() {
        onClick?()
    }
}
