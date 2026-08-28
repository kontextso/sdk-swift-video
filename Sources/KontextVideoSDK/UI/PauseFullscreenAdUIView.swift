import UIKit

/// The creative image over the whole player plus a Resume button styled by
/// `PauseFullscreenAd.Style`. Tapping the image opens the click-through URL.
final class PauseFullscreenAdUIView: UIView {
    private let ad: VideoAd
    private let style: PauseFullscreenAd.Style
    private let imageView = UIImageView()

    var onClick: (() -> Void)?
    var onResume: (() -> Void)?

    init(ad: VideoAd, style: PauseFullscreenAd.Style) {
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
        backgroundColor = style.backgroundColor

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
        addSubview(imageView)
        AdImageLoader.load(ad.creative.image.url, into: imageView)

        let resume = UIButton(type: .system)
        resume.setTitle(style.resumeTitle, for: .normal)
        resume.titleLabel?.font = style.resumeFont
        resume.setTitleColor(style.resumeTitleColor, for: .normal)
        resume.backgroundColor = style.resumeBackgroundColor
        resume.layer.cornerRadius = style.resumeCornerRadius
        resume.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        resume.translatesAutoresizingMaskIntoConstraints = false
        resume.addTarget(self, action: #selector(didTapResume), for: .touchUpInside)
        addSubview(resume)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            resume.centerXAnchor.constraint(equalTo: centerXAnchor),
            resume.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -style.resumeBottomInset),
        ])
    }

    @objc private func didTap() {
        guard let url = ad.creative.clickThroughUrl.flatMap(URL.init(string:)) else { return }
        onClick?()
        UIApplication.shared.open(url)
    }

    @objc private func didTapResume() {
        onResume?()
    }
}
