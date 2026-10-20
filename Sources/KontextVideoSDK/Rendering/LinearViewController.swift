import UIKit
import WebKit

/// The full-screen container the SDK presents for a linear ad. It owns nothing but the layout: the
/// ad owns the page and decides when it ends; the controller tells the ad when the system took the
/// presentation away (`.interrupted`).
@MainActor
final class LinearViewController: UIViewController {
    /// Set by the ad while it dismisses the controller itself, so `viewDidDisappear` is not an interruption.
    var isEndingByAd = false
    /// Called when the view left the screen and the ad did not ask for it.
    var onInterrupted: (() -> Void)?

    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Fires for every removal, programmatic or not, unlike presentationControllerDidDismiss: the one
        // place that sees a presenting controller dismissed underneath the ad.
        viewDisappeared(isBeingDismissed: isBeingDismissed, isMovingFromParent: isMovingFromParent, hasPresenter: presentingViewController != nil)
    }

    /// The decision `viewDidDisappear` makes, with its inputs explicit: a removal the ad did not ask for
    /// is an interruption.
    func viewDisappeared(isBeingDismissed: Bool, isMovingFromParent: Bool, hasPresenter: Bool) {
        guard !isEndingByAd, isBeingDismissed || isMovingFromParent || !hasPresenter else { return }
        onInterrupted?()
    }
}
