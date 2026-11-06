import SwiftUI
import UIKit

/// Shows a video ad from SwiftUI: place it over your player, usually in an `.overlay { }`, and set `ad` to a
/// loaded ad to show it, to `nil` (or another ad) to dismiss the one shown; it is dismissed too when the host
/// leaves the view hierarchy. An overlay or pause ad shows where the host is placed; a linear ad is presented
/// full screen from the top view controller of the host's window and is never dismissed by the host: it ends by
/// itself or by the viewer, and its `onEnd` still comes after the host left.
///
/// The host is the ad's delegate: hear the ad through `onImpression`, `onClick` and `onEnd`, and set your
/// state's ad back to `nil` in `onEnd`. `onShowFailed` means it could not be shown, for the reasons `show`
/// throws (`anotherAdShowing`, `contentPaused`, …): nothing was shown, and `onEnd` does not follow. An ad is tried
/// once: passing the same ad again on later updates does nothing, so `onShowFailed` cannot loop with your view's
/// updates; to try it again, pass `nil` (or another ad) and then that ad. `insets` keep an overlay or pause ad
/// clear of your own controls. Taps outside the ad go through to your player.
///
/// `insets` are read when the ad shows: changing them while it is on screen does not move it. The host becomes
/// the ad's delegate, replacing yours, and lets go of it after a failed show: listen through these closures.
/// Keep the `VideoAds` on your model object (an `ObservableObject` you hold with `@StateObject`), not in the view
/// struct, and destroy it when the viewer leaves the episode. The callbacks keep the names SwiftUI uses for its
/// own (`onAppear`, `onSubmit`); the Kotlin SDK's Compose host names them `onClicked`, `onEnded`.
@MainActor
public struct VideoAdHost: UIViewRepresentable {
    let ad: VideoAd?
    let insets: UIEdgeInsets
    let onShowFailed: ((VideoAd, VideoAdError) -> Void)?
    let onImpression: ((VideoAd) -> Void)?
    let onClick: ((VideoAd, VideoAd.Click) -> Void)?
    let onEnd: ((VideoAd, VideoAd.EndReason) -> Void)?

    /// A host for `ad` (`nil` shows nothing), placed where an overlay or pause ad goes. Every callback runs on the
    /// main actor, `onEnd` exactly once per ad shown; `onShowFailed` instead of any other for an ad that could not
    /// be shown.
    public init(
        ad: VideoAd?,
        insets: UIEdgeInsets = .zero,
        onShowFailed: ((VideoAd, VideoAdError) -> Void)? = nil,
        onImpression: ((VideoAd) -> Void)? = nil,
        onClick: ((VideoAd, VideoAd.Click) -> Void)? = nil,
        onEnd: ((VideoAd, VideoAd.EndReason) -> Void)? = nil
    ) {
        self.ad = ad
        self.insets = insets
        self.onShowFailed = onShowFailed
        self.onImpression = onImpression
        self.onClick = onClick
        self.onEnd = onEnd
    }

    public func makeUIView(context: Context) -> UIView {
        VideoAdSlotView()
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let slot = uiView as? VideoAdSlotView else { return }
        slot.insets = insets
        slot.onShowFailed = onShowFailed
        slot.onImpression = onImpression
        slot.onClick = onClick
        slot.onEnd = onEnd
        // After this update: showing or dismissing calls back into the app, which changes its state.
        slot.request(ad)
    }

    public static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? VideoAdSlotView)?.dismantle()
    }
}

/// The view behind `VideoAdHost`: shows the ad it is given once it is in a window and has a size, replaces or
/// dismisses it when given another or `nil`, and passes taps outside the ad through.
@MainActor
final class VideoAdSlotView: UIView, VideoAdDelegate {
    var insets: UIEdgeInsets = .zero
    var onShowFailed: ((VideoAd, VideoAdError) -> Void)?
    var onImpression: ((VideoAd) -> Void)?
    var onClick: ((VideoAd, VideoAd.Click) -> Void)?
    var onEnd: ((VideoAd, VideoAd.EndReason) -> Void)?

    /// The ad the slot was last given, until it ends or another replaces it.
    private(set) var ad: VideoAd?
    /// The ad last passed to `set`, shown or not, failed or not: the same one again does nothing, so a failed show
    /// is not tried again until the app passes something else. Weak: a failed ad is not kept alive to remember it.
    private weak var requested: VideoAd?
    /// Given and not shown yet: it shows at the first moment the view is in a window with a size.
    private var isPending = false
    /// The ad SwiftUI's latest update asked for, applied after that update (`request`).
    private var wanted: VideoAd?
    /// An apply of `wanted` is queued: a burst of updates folds into one.
    private var isApplyScheduled = false
    /// SwiftUI removed the host (`dismantleUIView`): nothing is adopted or shown here any more, and the end of an ad
    /// it dismissed is told after SwiftUI's update.
    private(set) var isDismantled = false
    /// Slots let go of while their linear ad plays: kept until its `didEnd`, which the app still needs to hear.
    private static var awaitingLinearEnd: [VideoAdSlotView] = []

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// SwiftUI's update asks for `ad`: applied (`set`) on the main queue after the update, since showing and
    /// dismissing call back into the app, which changes its state. Only the latest wish is applied, and none after
    /// `dismantle()`: a show queued before the host left must not adopt or show the ad in a view that is leaving.
    func request(_ ad: VideoAd?) {
        guard !isDismantled else { return }
        wanted = ad
        guard !isApplyScheduled else { return }
        isApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isApplyScheduled = false
            guard !isDismantled else { return }
            set(wanted)
        }
    }

    /// SwiftUI removes the host: the ad shown here is dismissed at once, freeing the app's one slot before SwiftUI
    /// goes on; its `onEnd` comes after the update. A linear ad plays on, and its end is still heard.
    func dismantle() {
        isDismantled = true
        wanted = nil
        set(nil)
    }

    /// Shows `ad` here, replacing the one shown; `nil` dismisses it. The same ad again does nothing, also after its
    /// show failed: it is tried again only once something else (`nil` or another ad) was passed in between. An ad
    /// shown elsewhere, or already ended, is left alone.
    func set(_ ad: VideoAd?) {
        if ad === requested { return }
        requested = ad
        let previous = self.ad
        self.ad = nil
        isPending = false
        if let previous { release(previous) }
        guard let ad, !ad.wasShown, !ad.hasEnded else { return }
        self.ad = ad
        ad.delegate = self
        isPending = true
        showIfPossible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        showIfPossible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        showIfPossible()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func showIfPossible() {
        guard !isDismantled, isPending, let ad, let window, bounds.width > 0, bounds.height > 0 else { return }
        isPending = false
        do {
            if ad.format == .linear {
                // From this host's own window: with two scenes, the key window may be the other one.
                guard let presenter = LinearAdViewController.topPresenter(in: window) else { throw VideoAdError.cannotShowNow }
                try ad.show(from: presenter)
            } else {
                try ad.show(in: self, insets: insets)
            }
        } catch {
            if self.ad === ad { self.ad = nil }
            if ad.delegate === self { ad.delegate = nil }
            if let error = error as? VideoAdError { onShowFailed?(ad, error) }
        }
    }

    // A linear ad ends by itself or by the viewer (dismiss() does not apply to it): it keeps playing, and this
    // slot stays its delegate until its end.
    private func release(_ ad: VideoAd) {
        if ad.format == .linear, ad.wasShown, !ad.hasDeliveredEnd {
            // Also while it is being dismissed (`hasEnded` already, `didEnd` not yet): the end is still owed.
            Self.awaitingLinearEnd.append(self)
        } else if ad.wasShown, !ad.hasEnded {
            ad.dismiss() // its didEnd reaches onEnd
        }
        if !ad.wasShown, ad.delegate === self { ad.delegate = nil }
    }

    func videoAdDidRecordImpression(_ ad: VideoAd) {
        onImpression?(ad)
    }

    func videoAd(_ ad: VideoAd, didClick click: VideoAd.Click) {
        onClick?(ad, click)
    }

    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        if self.ad === ad { self.ad = nil }
        Self.awaitingLinearEnd.removeAll { $0 === self }
        guard let onEnd else { return }
        // Dismissed by SwiftUI's removal: the app's state changes after that update, not inside it.
        if isDismantled {
            DispatchQueue.main.async { onEnd(ad, reason) }
        } else {
            onEnd(ad, reason)
        }
    }
}
