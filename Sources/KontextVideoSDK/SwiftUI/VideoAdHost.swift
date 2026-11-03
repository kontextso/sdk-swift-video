import SwiftUI
import UIKit

/// Shows a video ad from SwiftUI: place it over your player, usually in an `.overlay { }`, and set `ad` to a
/// loaded ad to show it, to `nil` (or another ad) to dismiss the one shown; it is dismissed too when the host
/// leaves the view hierarchy. An overlay or pause ad shows where the host is placed; a linear ad is presented
/// full screen from the top view controller and is never dismissed by the host: it ends by itself or by the
/// viewer.
///
/// The host is the ad's delegate: hear the ad through `onImpression`, `onClick` and `onEnd`, and set your
/// state's ad back to `nil` in `onEnd`. `onShowFailed` means it could not be shown, for the reasons `show`
/// throws (`anotherAdShowing`, `contentPaused`, …): nothing was shown, and `onEnd` does not follow. `insets`
/// keep an overlay or pause ad clear of your own controls. Taps outside the ad go through to your player.
///
/// Keep the `VideoAds` on your model (`@StateObject`), not in the view struct, and destroy it when the viewer
/// leaves the episode.
@MainActor
public struct VideoAdHost: UIViewRepresentable {
    let ad: VideoAd?
    let insets: UIEdgeInsets
    let onShowFailed: ((VideoAd, VideoAdError) -> Void)?
    let onImpression: ((VideoAd) -> Void)?
    let onClick: ((VideoAd, VideoAd.Click) -> Void)?
    let onEnd: ((VideoAd, VideoAd.EndReason) -> Void)?

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
        let ad = ad
        DispatchQueue.main.async { [weak slot] in slot?.set(ad) }
    }

    public static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? VideoAdSlotView)?.set(nil)
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
    /// Given and not shown yet: it shows at the first moment the view is in a window with a size.
    private var isPending = false
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

    /// Shows `ad` here, replacing the one shown; `nil` dismisses it. The same ad again does nothing; an ad shown
    /// elsewhere, or already ended, is left alone.
    func set(_ ad: VideoAd?) {
        if ad === self.ad { return }
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
        guard isPending, let ad, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        isPending = false
        do {
            if ad.format == .linear {
                try ad.show()
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
        if ad.wasShown, !ad.hasEnded {
            if ad.format == .linear {
                Self.awaitingLinearEnd.append(self)
            } else {
                ad.dismiss() // its didEnd reaches onEnd
            }
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
        onEnd?(ad, reason)
        Self.awaitingLinearEnd.removeAll { $0 === self }
    }
}
