import UIKit

/// Pause ad: the paused frame stays visible; a dark gradient rises from the
/// bottom and carries the ad content — brand, headline, body, a Resume
/// button, the CTA, and a product thumbnail. An "AD" badge sits top-right.
final class PauseAdUIView: UIView {
    private let creative: InstreamAdCreative
    private let gradient = CAGradientLayer()

    /// Called by the Resume button; the session resumes playback, which
    /// hides the ad via the playback-status observation.
    var onResume: (() -> Void)?

    init(creative: InstreamAdCreative) {
        self.creative = creative
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    private func setUp() {
        backgroundColor = .clear
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.25).cgColor,
            UIColor.black.withAlphaComponent(0.45).cgColor,
            UIColor.black.withAlphaComponent(0.92).cgColor,
        ]
        gradient.locations = [0, 0.45, 0.8]
        layer.addSublayer(gradient)

        let adBadge = UILabel()
        adBadge.text = "AD"
        adBadge.font = .systemFont(ofSize: 11, weight: .bold)
        adBadge.textColor = .black
        adBadge.textAlignment = .center
        adBadge.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        adBadge.layer.cornerRadius = 4
        adBadge.clipsToBounds = true
        adBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(adBadge)

        let brand = UILabel()
        brand.text = creative.advertiser
        brand.font = .systemFont(ofSize: 13, weight: .semibold)
        brand.textColor = UIColor.systemOrange
        brand.isHidden = creative.advertiser == nil

        let headline = UILabel()
        headline.text = creative.headline
        headline.font = .systemFont(ofSize: 26, weight: .bold)
        headline.textColor = .white
        headline.numberOfLines = 0

        let body = UILabel()
        body.text = creative.body
        body.font = .systemFont(ofSize: 14)
        body.textColor = UIColor.white.withAlphaComponent(0.8)
        body.numberOfLines = 0

        let resume = UIButton(type: .system)
        resume.setTitle("  Resume", for: .normal)
        resume.setImage(UIImage(systemName: "play.fill"), for: .normal)
        resume.tintColor = .white
        resume.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        resume.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        resume.layer.cornerRadius = 12
        resume.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        resume.addTarget(self, action: #selector(didTapResume), for: .touchUpInside)

        let cta = UIButton(type: .system)
        cta.setTitle("\(creative.cta.text) ↗", for: .normal)
        cta.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cta.setTitleColor(.white, for: .normal)
        cta.backgroundColor = UIColor.systemOrange
        cta.layer.cornerRadius = 12
        cta.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        cta.addTarget(self, action: #selector(didTapCTA), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [resume, cta])
        buttons.axis = .vertical
        buttons.alignment = .leading
        buttons.spacing = 10

        let text = UIStackView(arrangedSubviews: [brand, headline, body, buttons])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 8
        text.setCustomSpacing(14, after: body)

        let thumbnail = UIImageView()
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 12
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: 112),
            thumbnail.heightAnchor.constraint(equalToConstant: 140),
        ])
        AdImageLoader.load(creative.image.url, into: thumbnail)

        let content = UIStackView(arrangedSubviews: [text, thumbnail])
        content.axis = .horizontal
        content.alignment = .bottom
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            adBadge.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            adBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            adBadge.widthAnchor.constraint(equalToConstant: 34),
            adBadge.heightAnchor.constraint(equalToConstant: 20),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -96),
        ])
    }

    @objc private func didTapResume() {
        onResume?()
    }

    @objc private func didTapCTA() {
        guard let url = URL(string: creative.cta.url) else { return }
        UIApplication.shared.open(url)
    }
}
