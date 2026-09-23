import KontextKit
import UIKit

/// Shared machinery of every placement: the pending queue, the optional
/// reveal delay, tracking, viewability, and teardown. Subclasses build the
/// view, lay it out, and add format-specific behaviour (video playback).
@MainActor
public class AdPlacement {
    public let format: VideoAdFormat
    public let videoId: String

    /// Ads not yet shown, in the order the server returned them.
    public private(set) var pending: [VideoAd] = []

    /// `true` when an ad is loaded and none is on screen or about to be.
    public var isReady: Bool {
        !isDestroyed && view == nil && revealTask == nil && !pending.isEmpty
    }

    public private(set) var isDestroyed = false

    let emit: (VideoAdEvent) -> Void
    var loadHandler: (() -> Void)?

    private(set) var view: UIView?
    private(set) var current: VideoAd?
    private(set) var tracker: AdTracker?
    private var meter: ViewabilityMeter?
    private var revealTask: Task<Void, Never>?
    private var shownAt: Date?

    init(format: VideoAdFormat, videoId: String, emit: @escaping (VideoAdEvent) -> Void) {
        self.format = format
        self.videoId = videoId
        self.emit = emit
    }

    /// Requests another ad for this placement only (one `/instream/preload`
    /// with just this format). Same as `VideoAds.load(formats: [format])`.
    public func load() {
        loadHandler?()
    }

    /// Removes the ad if it is on screen (or cancels a pending reveal). Call
    /// whenever playback resumes. Fires `overlay_view_duration`, plus `close`
    /// when `userDismissed`.
    public func hide() {
        hide(userDismissed: false)
    }

    func hide(userDismissed: Bool) {
        revealTask?.cancel()
        revealTask = nil
        guard let view else { return }
        meter?.end()
        meter = nil
        willHide(userDismissed: userDismissed)
        tracker?.fire(.overlayViewDuration)
        if userDismissed { tracker?.fire(.close) }
        view.removeFromSuperview()
        self.view = nil
        current = nil
        tracker = nil
        shownAt = nil
    }

    // MARK: - Subclass hooks

    /// Build the ad view, wire its callbacks to `onClick` / `onImageLoaded`,
    /// and return it. Called after the reveal delay.
    func makeView(for ad: VideoAd) -> UIView {
        fatalError("subclass")
    }

    /// Add the view to the container and activate its constraints.
    func mount(_ view: UIView, in container: UIView) {
        fatalError("subclass")
    }

    /// Called before the view is removed on `hide`; the tracker is still
    /// alive. Video placements fire `skip` here.
    func willHide(userDismissed: Bool) {}

    // MARK: - Shared flow

    /// Shows the next ad in `container` — immediately, unless the server
    /// set `trigger.delay_ms` for this ad, in which case a `hide()` during
    /// the wait cancels the reveal and the ad stays queued for the next
    /// pause. The ad is consumed only when it actually appears.
    /// Returns `false` when ``isReady`` is `false`.
    @discardableResult
    func present(in container: UIView) -> Bool {
        guard isReady, let ad = pending.first else { return false }
        let delayMs = ad.trigger.delayMs ?? 0
        guard delayMs > 0 else {
            pending.removeFirst()
            reveal(ad, in: container)
            return true
        }
        revealTask = Task { [weak self, weak container] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled, let self, let container,
                  let next = self.pending.first, next.adId == ad.adId else { return }
            self.revealTask = nil
            self.pending.removeFirst()
            self.reveal(next, in: container)
        }
        return true
    }

    private func reveal(_ ad: VideoAd, in container: UIView) {
        let tracker = AdTracker(tracking: ad.tracking)
        // `current` is set before `mount` so subclasses can read the ad's
        // placement while laying out.
        self.current = ad
        self.tracker = tracker
        let view = makeView(for: ad)
        view.translatesAutoresizingMaskIntoConstraints = false
        mount(view, in: container)
        view.alpha = 0
        UIView.animate(withDuration: 0.3) { view.alpha = 1 }
        self.view = view
        emit(.shown(VideoAdEvent.AdData(format: format, videoId: videoId, adId: ad.adId)))
    }

    /// The creative could not render (image failed to load, video URL
    /// bad). Removes the ad without firing view/impression tracking (there
    /// was no view) and surfaces `.error`, so the app is never left with a
    /// blank ad on screen. Subclasses that own an exit callback override.
    func onCreativeFailed(_ message: String) {
        revealTask?.cancel()
        revealTask = nil
        meter?.end()
        meter = nil
        willHide(userDismissed: false)
        view?.removeFromSuperview()
        view = nil
        current = nil
        tracker = nil
        emit(.error(VideoAdEvent.ErrorData(videoId: videoId, message: message)))
    }

    /// The creative is on screen (image painted / first video frame): this
    /// is the impression.
    func onCreativeRendered() {
        guard let view, let tracker else { return }
        tracker.fire(.impression)
        tracker.fire(.creativeView)
        shownAt = Date()
        let meter = ViewabilityMeter(view: view) { [weak tracker] verdict in
            tracker?.fire(verdict)
        }
        meter.start()
        self.meter = meter
    }

    /// Opens the click-through via the server (`/impression/{bid}/redirect`
    /// records the click and forwards to the advertiser) in the in-app
    /// browser (KontextKit's `SFSafariViewController` host, which also
    /// dismisses itself when a deep link hands off to another app). Falls
    /// back to the system for non-http schemes.
    func onClick() {
        guard let ad = current, let url = URL(string: ad.tracking.clickThrough) else { return }
        emit(.clicked(VideoAdEvent.AdData(format: format, videoId: videoId, adId: ad.adId)))
        if !InAppBrowserManager.shared.present(url: url) {
            UIApplication.shared.open(url)
        }
    }

    func onUserDismiss() {
        guard let ad = current else { return }
        hide(userDismissed: true)
        emit(.closed(VideoAdEvent.AdData(format: format, videoId: videoId, adId: ad.adId)))
    }

    func append(_ ads: [VideoAd]) {
        guard !isDestroyed else { return }
        pending += ads
    }

    func moveToFront(_ index: Int) {
        guard pending.indices.contains(index), index != 0 else { return }
        let ad = pending.remove(at: index)
        pending.insert(ad, at: 0)
    }

    /// Tears the placement down: fires the end-of-display pings for an ad on
    /// screen, keeps its view alive for `Constants.teardownDelay`, then
    /// removes it and drops pending ads. Called by `VideoAds.destroy()`.
    func destroy() async {
        guard !isDestroyed else { return }
        isDestroyed = true
        pending.removeAll()
        revealTask?.cancel()
        revealTask = nil
        guard let view else {
            // No view on screen, but a subclass may still hold resources
            // (an interstitial's player) — let it tear down.
            willHide(userDismissed: false)
            return
        }
        view.isUserInteractionEnabled = false
        willHide(userDismissed: false)
        meter?.end()
        meter = nil
        tracker?.fire(.overlayViewDuration)
        // OM session finish goes here.
        try? await Task.sleep(nanoseconds: UInt64(Constants.teardownDelay * 1_000_000_000))
        view.removeFromSuperview()
        if self.view === view {
            self.view = nil
            current = nil
            tracker = nil
        }
    }
}
