import UIKit

/// The overlay ad card the SDK mounts over the attached player while the
/// ad's time window is on screen. Image + headline + body + CTA; tapping
/// anywhere opens the click-through URL.
final class OverlayAdUIView: UIView {
    private let creative: InstreamAdCreative

    init(creative: InstreamAdCreative) {
        self.creative = creative
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 72),
            imageView.heightAnchor.constraint(equalToConstant: 72),
        ])
        loadImage(into: imageView)

        let headline = UILabel()
        headline.text = creative.headline
        headline.font = .systemFont(ofSize: 14, weight: .semibold)
        headline.textColor = .white
        headline.numberOfLines = 2

        let body = UILabel()
        body.text = creative.body
        body.font = .systemFont(ofSize: 12)
        body.textColor = UIColor.white.withAlphaComponent(0.75)
        body.numberOfLines = 2

        let cta = UILabel()
        cta.text = creative.cta.text
        cta.font = .systemFont(ofSize: 12, weight: .semibold)
        cta.textColor = .white

        let ctaPill = UIView()
        ctaPill.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        ctaPill.layer.cornerRadius = 12
        cta.translatesAutoresizingMaskIntoConstraints = false
        ctaPill.addSubview(cta)
        NSLayoutConstraint.activate([
            cta.topAnchor.constraint(equalTo: ctaPill.topAnchor, constant: 5),
            cta.bottomAnchor.constraint(equalTo: ctaPill.bottomAnchor, constant: -5),
            cta.leadingAnchor.constraint(equalTo: ctaPill.leadingAnchor, constant: 12),
            cta.trailingAnchor.constraint(equalTo: ctaPill.trailingAnchor, constant: -12),
        ])

        let ctaRow = UIStackView(arrangedSubviews: [ctaPill, UIView()])
        ctaRow.axis = .horizontal

        let text = UIStackView(arrangedSubviews: [headline, body, ctaRow])
        text.axis = .vertical
        text.spacing = 4
        text.setCustomSpacing(8, after: body)

        let content = UIStackView(arrangedSubviews: [imageView, text])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    private func loadImage(into imageView: UIImageView) {
        guard let url = URL(string: creative.image.url) else { return }
        Task { [weak imageView] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            imageView?.image = UIImage(data: data)
        }
    }

    @objc private func didTap() {
        guard let url = URL(string: creative.cta.url) else { return }
        UIApplication.shared.open(url)
    }
}
