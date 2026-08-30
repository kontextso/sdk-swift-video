import UIKit

/// Shared machinery of the two pause placements: the pending queue, the
/// reveal delay, tracking, viewability, and teardown. Subclasses only build
/// the view and lay it out.
@MainActor
public class PausePlacement {
    public let format: VideoAdFormat
    public let externalId: String

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
    private var current: VideoAd?
    private var tracker: AdTracker?
    private var meter: ViewabilityMeter?
    private var revealTask: Task<Void, Never>?
    private var shownAt: Date?

    init(format: VideoAdFormat, externalId: String, emit: @escaping (VideoAdEvent) -> Void) {
        self.format = format
        self.externalId = externalId
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

    // MARK: - Shared flow

    /// Consumes the next ad and shows it in `container` after the server's
    /// reveal delay (`trigger.delay_ms`). A `hide()` during the delay cancels
    /// the reveal — a quick accidental tap never surfaces the ad.
    /// Returns `false` when ``isReady`` is `false`.
    @discardableResult
    func present(in container: UIView) -> Bool {
        guard isReady else { return false }
        let ad = pending.removeFirst()
        let delay = TimeInterval(ad.trigger.delayMs ?? 0) / 1000
        revealTask = Task { [weak self, weak container] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, let container else { return }
            self.revealTask = nil
            self.reveal(ad, in: container)
        }
        return true
    }

    private func reveal(_ ad: VideoAd, in container: UIView) {
        let tracker = AdTracker(tracking: ad.tracking)
        let view = makeView(for: ad)
        view.translatesAutoresizingMaskIntoConstraints = false
        mount(view, in: container)
        view.alpha = 0
        UIView.animate(withDuration: 0.3) { view.alpha = 1 }
        self.view = view
        self.current = ad
        self.tracker = tracker
        emit(.shown(VideoAdEvent.AdData(format: format, externalId: externalId, bidId: ad.bidId)))
    }

    /// The image is painted: this is the impression.
    func onImageLoaded() {
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
    /// records the click and forwards to the advertiser).
    func onClick() {
        guard let ad = current, let url = URL(string: ad.tracking.clickThrough) else { return }
        emit(.clicked(VideoAdEvent.AdData(format: format, externalId: externalId, bidId: ad.bidId)))
        UIApplication.shared.open(url)
    }

    func onUserDismiss() {
        guard let ad = current else { return }
        hide(userDismissed: true)
        emit(.closed(VideoAdEvent.AdData(format: format, externalId: externalId, bidId: ad.bidId)))
    }

    func append(_ ads: [VideoAd]) {
        guard !isDestroyed else { return }
        pending += ads
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
        guard let view else { return }
        view.isUserInteractionEnabled = false
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
