import UIKit

/// The full-screen host the SDK presents for an interstitial. Nothing but a
/// background: the ad view is mounted into `view` by the placement. Modal
/// and non-dismissable by gesture, so the only ways out are the ad's own
/// Close chip, completion, or the placement's `hide()`.
///
/// `.overFullScreen`, not `.fullScreen`: the latter removes the presenting
/// view from the hierarchy, which makes SwiftUI hosts fire `onDisappear`
/// on the player screen and tear down the content player under the ad.
final class InterstitialAdViewController: UIViewController {
    init(backgroundColor: UIColor) {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
        modalPresentationCapturesStatusBarAppearance = true
        view.backgroundColor = backgroundColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersStatusBarHidden: Bool { true }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
}
