import UIKit

/// The creative image as a rounded banner styled by `BannerStyle`, shared by
/// the pause overlay and the playing overlay. Tapping it opens the
/// click-through URL.
final class BannerAdUIView: UIView {
    private let ad: VideoAd
    private let style: BannerStyle
    private let imageView = UIImageView()

    var onClick: (() -> Void)?
    var onImageLoaded: (() -> Void)?
    var onImageFailed: ((String) -> Void)?

    init(ad: VideoAd, style: BannerStyle) {
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
            AdImageLoader.load(image.url, into: imageView,
                onLoaded: { [weak self] in self?.onImageLoaded?() },
                onFailed: { [weak self] message in self?.onImageFailed?(message) })
        } else {
            onImageFailed?("ad has no image")
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

extension AdPlacement {
    /// Lays a banner out inside `container` at `position` with `style`.
    func mountBanner(_ view: BannerAdUIView, in container: UIView, position: BannerPosition, style: BannerStyle) {
        container.addSubview(view)
        let margins = style.margins
        var width = max(container.bounds.width - margins.left - margins.right, 0)
        if let maxWidth = style.maxWidth { width = min(width, maxWidth) }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: view.height(forWidth: width)),
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: (margins.left - margins.right) / 2),
            position == .top
                ? view.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: margins.top)
                : view.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -margins.bottom),
        ])
    }
}
