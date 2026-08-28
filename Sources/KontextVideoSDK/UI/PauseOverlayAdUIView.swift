import UIKit

/// The creative image as a rounded banner. Tapping it opens the
/// click-through URL.
final class PauseOverlayAdUIView: UIView {
    private let ad: VideoAd
    private let imageView = UIImageView()

    var onClick: (() -> Void)?

    init(ad: VideoAd) {
        self.ad = ad
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
        AdImageLoader.load(ad.creative.image.url, into: imageView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    /// Height for a given width, from the creative's declared image size.
    func height(forWidth width: CGFloat) -> CGFloat {
        let image = ad.creative.image
        guard image.w > 0, image.h > 0 else { return width * 0.6 }
        return width * CGFloat(image.h) / CGFloat(image.w)
    }

    @objc private func didTap() {
        guard let url = ad.creative.clickThroughUrl.flatMap(URL.init(string:)) else { return }
        onClick?()
        UIApplication.shared.open(url)
    }
}
