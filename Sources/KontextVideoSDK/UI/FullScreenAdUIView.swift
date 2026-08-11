import UIKit

/// Full-screen ad takeover, used by both the swipe banner (between
/// episodes) and the pause ad (over the paused frame). Dismissed via the
/// close button; tapping the CTA opens the click-through URL.
final class FullScreenAdUIView: UIView {
    enum Style {
        /// Nearly opaque — shown between episodes.
        case swipeBanner
        /// Translucent — the paused frame stays visible behind the ad.
        case pauseAd

        var backgroundAlpha: CGFloat {
            switch self {
            case .swipeBanner: 0.94
            case .pauseAd: 0.78
            }
        }
    }

    private let creative: InstreamAdCreative
    private let style: Style
    var onClose: (() -> Void)?

    init(creative: InstreamAdCreative, style: Style) {
        self.creative = creative
        self.style = style
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        backgroundColor = UIColor.black.withAlphaComponent(style.backgroundAlpha)

        let adLabel = UILabel()
        adLabel.text = "AD"
        adLabel.font = .systemFont(ofSize: 11, weight: .bold)
        adLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.6).isActive = true
        loadImage(into: imageView)

        let headline = UILabel()
        headline.text = creative.headline
        headline.font = .systemFont(ofSize: 24, weight: .bold)
        headline.textColor = .white
        headline.numberOfLines = 0
        headline.textAlignment = .center

        let body = UILabel()
        body.text = creative.body
        body.font = .systemFont(ofSize: 15)
        body.textColor = UIColor.white.withAlphaComponent(0.75)
        body.numberOfLines = 0
        body.textAlignment = .center

        let cta = UIButton(type: .system)
        cta.setTitle(creative.cta.text, for: .normal)
        cta.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cta.setTitleColor(.black, for: .normal)
        cta.backgroundColor = .white
        cta.layer.cornerRadius = 22
        cta.contentEdgeInsets = UIEdgeInsets(top: 12, left: 32, bottom: 12, right: 32)
        cta.addTarget(self, action: #selector(didTapCTA), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [adLabel, imageView, headline, body, cta])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .white
        close.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        close.layer.cornerRadius = 16
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        addSubview(close)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            close.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            close.widthAnchor.constraint(equalToConstant: 32),
            close.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func loadImage(into imageView: UIImageView) {
        guard let url = URL(string: creative.image.url) else { return }
        Task { [weak imageView] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            imageView?.image = UIImage(data: data)
        }
    }

    @objc private func didTapCTA() {
        guard let url = URL(string: creative.cta.url) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func didTapClose() {
        onClose?()
    }
}
