import Foundation
import UIKit

/// One ad, returned by a placement's `load`. The app owns it: keep a reference until it is shown, drop it
/// and it is gone (the placement only holds it weakly). An ad is shown at most once.
///
/// Read-only facts about the ad for the app's own decisions (an auction, a debug screen); times are
/// seconds and `expirationDate` is a `Date`, whatever the wire sends.
@MainActor
public final class VideoAd {
    public struct Price: Sendable, Equatable {
        public enum Precision: Sendable {
            /// A DSP's clearing price.
            case exact
            /// Our own or house demand, a forecast.
            case estimated
        }

        /// Per 1,000 impressions.
        public let value: Double
        /// ISO 4217.
        public let currency: String
        public let precision: Precision
    }

    /// The box the creative was built for, in points. The SDK scales it down to 50 % of this when the
    /// player is smaller, and refuses to show below that.
    public struct Size: Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    /// Where the server placed the ad, among the `positions` the app offered.
    public enum Position: Sendable, Equatable {
        case top
        case bottom
        case fullscreen
    }

    public enum Trigger: Sendable, Equatable {
        /// The app decides the moment.
        case manual
        /// Timed mode: show it between `from` and `to`, seconds in content time.
        case window(from: TimeInterval, to: TimeInterval)
    }

    /// What the viewer earns when a rewarded linear ad completes.
    public struct Reward: Sendable, Equatable {
        public let label: String
        public let amount: Double
    }

    /// Why a loaded ad can no longer be shown.
    public enum InvalidationReason: Sendable, Equatable {
        /// `expirationDate` passed before the ad was shown.
        case expired
        /// `user`, `regulatory` or `variantId` changed; the next load carries the new values.
        case targetingChanged
        /// The `VideoAds` was destroyed.
        case destroyed
        /// The creative died while the ad waited to be shown (for example the web content process was
        /// terminated). `code` is the VAST error code the SDK fired.
        case creativeFailed(code: Int)
        /// `show` found the player's view below 50 % of the ad's size.
        case containerTooSmall
        /// Timed mode: the window's end passed (by time or by a forward seek) before the ad was shown, or
        /// before an overlay's `duration` still fitted.
        case windowPassed
        /// Timed mode: the viewer seeked, so an ad chosen for the old content time is stale.
        case seeked
    }

    public var id: String { facts.id }
    public var placementId: String { facts.placementId }
    public var format: AdFormat { facts.format }
    public var price: Price { facts.price }
    /// When the ad stops being showable. The server sends a relative lifetime; this is it as a `Date`, for
    /// the app's eyes. The SDK's own check runs on the monotonic clock, so a changed device clock cannot
    /// expire an ad early or late.
    public var expirationDate: Date { facts.expirationDate }
    /// `nil` for a linear ad.
    public var position: Position? { facts.position }
    /// `nil` for a linear ad and for a full-screen pause ad.
    public var size: Size? { facts.size }
    /// Overlay: how long it stays on screen. Linear: the video's length. Seconds; `nil` for a pause ad.
    public var duration: TimeInterval? { facts.duration }
    /// Linear: seconds until the Close may appear; `nil` means no Close before the video completes.
    public var skipOffset: TimeInterval? { facts.skipOffset }
    /// Set on a rewarded linear ad.
    public var reward: Reward? { facts.reward }
    public var trigger: Trigger { facts.trigger }

    /// Whether `show` can be called: the creative is loaded, the ad was not shown yet and not invalidated.
    /// A hint for "show or load" decisions, not the authority: the box is measured only at `show`, and
    /// `show` throws when it cannot begin.
    public var isReady: Bool {
        isLoaded && !wasShown && invalidationReason == nil && !isExpired
    }

    /// Why the ad was invalidated, once it was.
    public private(set) var invalidationReason: InvalidationReason?

    /// Receives the ad's moments. Held weakly. Timed mode: a window that opened before the delegate was
    /// set is delivered the moment it is, so `load()` returning and `ad.delegate = self` on the next line
    /// never miss it, whatever the sampler did in between.
    public weak var delegate: (any VideoAdDelegate)? {
        didSet { if windowReached, delegate != nil { deliverWindow() } }
    }

    /// `true` from a successful `show` on; an ad is shown at most once.
    public private(set) var wasShown = false
    /// `true` once `didEnd` was delivered.
    public private(set) var hasEnded = false
    /// Timed mode: the sampler saw the window open while the ad was ready.
    private var windowReached = false
    /// Timed mode: `videoAdDidReachWindow` was delivered.
    private(set) var windowDelivered = false

    /// Below this share of the nominal size the ad is not shown.
    static let minimumScale: CGFloat = 0.5

    /// The wire object, for the steps that render and track it.
    let ad: AdPayload
    /// The read-only facts, shared with `Bid`; the expiry counts from the response.
    let facts: Facts
    /// The WebView and the protocol with the frame page. Created with the ad; the page starts loading at
    /// once, so `load` can return a ready ad.
    let bridge: FrameBridge
    /// The page reported `ad.loaded`.
    private(set) var isLoaded = false
    /// `load` waiting for the page.
    private var loadContinuation: CheckedContinuation<Void, Error>?
    /// The `VideoAds` that loaded it; told when the ad is shown and when it ends.
    weak var owner: VideoAds?
    /// The view the SDK put into the player's view for an overlay or pause ad.
    private var hostView: UIView?
    /// The controller the SDK presented for a linear ad.
    private var linearController: LinearViewController?
    /// `video.complete` arrived; the next `ad.close` is the end card closing, not the viewer giving up.
    private var completed = false
    /// Delivers `didInvalidate(.expired)` when the time comes.
    private var expiryTask: Task<Void, Never>?
    /// Fires the `tracking` entries, each once.
    private let tracker: Tracker
    /// The page owns the 3 s video-start timeout and reports it as `ad.error`; this is the backstop for a
    /// page that is itself dead after `ad.show`.
    private var startBackstop: Task<Void, Never>?
    static var videoStartBackstop: TimeInterval = 5
    /// Decides `viewable` / `notViewable` while the ad is on screen.
    private var meter: ViewabilityMeter?
    /// Removes an overlay when its `duration` elapses; the app runs no timer.
    private var durationTask: Task<Void, Never>?

    /// `facts` are the bid's when the ad comes from one, so the expiry counts from the response, not from
    /// the moment the bid was loaded. The page starts loading at once.
    init(ad: AdPayload, facts: Facts? = nil) {
        self.ad = ad
        self.facts = facts ?? Facts(ad: ad, receivedAt: ProcessInfo.processInfo.systemUptime)
        switch ad.rendering {
        case .frame(let url):
            bridge = FrameBridge(adId: ad.id, url: url, isVideo: ad.creative == .video)
        }
        tracker = Tracker(adId: ad.id, entries: ad.tracking)
        tracker.contentPlayhead = { [weak self] in self?.owner?.playhead ?? 0 }
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        bridge.load()
        let remaining = self.facts.remainingLifetime
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, !Task.isCancelled, !wasShown else { return }
            invalidate(.expired)
        }
    }

    // MARK: Showing

    /// Shows an overlay or pause ad inside `view`, the one the content plays in (the view that fills the
    /// video area, not the screen), at the ad's `position` and `size`; a full-screen pause ad fills it.
    /// Throws when presentation cannot begin, with nothing fired: `alreadyShown`, `invalidated`,
    /// `containerTooSmall` (the ad is discarded). From here until `didEnd` the SDK retains the ad.
    public func show(in view: UIView) throws {
        guard format != .linear else {
            Environment.assertionFailure("KontextVideo: a linear ad is shown with show(from:)")
            throw VideoAdError.presenterUnavailable
        }
        try checkShowable()
        let container = view
        let host = UIView(frame: try frame(in: container.bounds))
        host.autoresizingMask = position == .fullscreen ? [.flexibleWidth, .flexibleHeight] : [.flexibleLeftMargin, .flexibleRightMargin, position == .top ? .flexibleBottomMargin : .flexibleTopMargin]
        let webView = bridge.takeWebView()
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(webView)
        container.addSubview(host)
        hostView = host
        begin()
    }

    /// Presents a linear ad full screen. From `viewController` when given, which must be on screen
    /// and not already presenting; with `nil` (the default) from the key window's top view controller,
    /// as AdMob's `present(from: nil)` and MAX's `showAd()` do. Pass the controller when the guess would
    /// be wrong: a player presented as a sheet, a second window, a hosting controller that is not yours.
    /// Throws when presentation cannot begin, with nothing fired: `alreadyShown`, `invalidated`,
    /// `presenterUnavailable` (the ad stays ready; try again later or pass the right controller). Only the
    /// SDK dismisses it: the video completing, a skip, a close, an error, or an interruption, each ending
    /// in one `didEnd`. From here until `didEnd` the SDK retains the ad.
    public func show(from viewController: UIViewController? = nil) throws {
        guard format == .linear else {
            Environment.assertionFailure("KontextVideo: an overlay or pause ad is shown with show(in:)")
            throw VideoAdError.presenterUnavailable
        }
        try checkShowable()
        let presenter: UIViewController
        if let viewController {
            guard viewController.view.window != nil, viewController.presentedViewController == nil else {
                Logger.warning("ad \(id.prefix(8)): cannot present, the view controller is not on screen or already presenting")
                throw VideoAdError.presenterUnavailable
            }
            presenter = viewController
        } else {
            guard let top = Self.topViewController() else {
                Logger.warning("ad \(id.prefix(8)): cannot present, no view controller on the key window can present now")
                throw VideoAdError.presenterUnavailable
            }
            presenter = top
        }
        let controller = LinearViewController(webView: bridge.takeWebView())
        controller.onInterrupted = { [weak self] in
            guard let self else { return }
            Logger.warning("ad \(id.prefix(8)): presentation interrupted")
            end(.interrupted)
        }
        linearController = controller
        // The meter starts once the presentation is on screen; a tick during the transition would read
        // exposure 0 and make the page pause the video it has just started.
        presenter.present(controller, animated: true) { [weak self] in
            self?.startMeter()
        }
        begin(startMeter: false)
    }

    /// The key window's root controller, followed through what it presents to the top, as the peers do
    /// (AdMob 11, MAX). `nil` when there is no key window or the top controller cannot present: it is
    /// being dismissed or is mid-transition; a system alert or sheet on top is a plain controller that
    /// can, and the ad goes over it, as a peer's would.
    static func topViewController() -> UIViewController? {
        guard var controller = Environment.keyWindow()?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        guard controller.view.window != nil, !controller.isBeingPresented, !controller.isBeingDismissed else { return nil }
        return controller
    }

    /// Ends an overlay or pause ad because the app says so: the page is removed, `overlayViewDuration`
    /// fires, and the delegate gets `didEnd(.dismissed)`. Terminal; the ad cannot be shown again. For an
    /// overlay this is the way to end it before its `duration` (the content ended, a seek); left alone,
    /// the SDK removes it when the duration elapses, with `didEnd(.completed)`.
    public func dismiss() {
        guard wasShown, !hasEnded else { return }
        Logger.debug("ad \(id.prefix(8)): dismissed by the app")
        end(.dismissed)
    }

    private func checkShowable() throws {
        if wasShown { throw VideoAdError.alreadyShown }
        if let owner, owner.isShowingAnAd { throw VideoAdError.anotherAdShowing }
        if isExpired { invalidate(.expired) }
        if let reason = invalidationReason { throw VideoAdError.invalidated(reason) }
        guard isLoaded else { throw VideoAdError.invalidated(.creativeFailed(code: ad.creative == .video ? 400 : 500)) }
    }

    /// Where the ad goes in the player's view: the nominal size, scaled down to fit, never below 50 %.
    private func frame(in bounds: CGRect) throws -> CGRect {
        guard position != .fullscreen, let size else { return bounds }
        let nominal = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
        let scale = min(1, bounds.width / nominal.width, bounds.height / nominal.height)
        guard scale >= Self.minimumScale else {
            let minimum = CGSize(width: (nominal.width * Self.minimumScale).rounded(.up), height: (nominal.height * Self.minimumScale).rounded(.up))
            Logger.warning("ad \(id.prefix(8)): player view \(Int(bounds.width))×\(Int(bounds.height)) is below 50 % of the ad's \(size.width)×\(size.height); discarded")
            invalidate(.containerTooSmall)
            throw VideoAdError.containerTooSmall(minimum: minimum)
        }
        let scaled = CGSize(width: (nominal.width * scale).rounded(), height: (nominal.height * scale).rounded())
        let x = ((bounds.width - scaled.width) / 2).rounded()
        let y = position == .top ? 0 : bounds.height - scaled.height
        return CGRect(x: x, y: y, width: scaled.width, height: scaled.height)
    }

    /// Presentation began: the page is told, the owner retains the ad; `show` returning is the app's signal.
    private func begin(startMeter: Bool = true) {
        wasShown = true
        RenderedAds.remove(self)
        expiryTask?.cancel()
        owner?.adDidBeginShowing(self)
        bridge.show()
        Logger.info("ad \(id.prefix(8)): shown")
        // At `ad.show`: creativeView and the AdChoices icon's view; the impression too for an image
        // creative, while a video's waits for its first frame.
        tracker.fire("creativeView")
        tracker.fire("iconView")
        if ad.creative == .image {
            recordImpression()
        } else {
            startBackstop = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.videoStartBackstop * 1_000_000_000))
                guard let self, !Task.isCancelled, !hasEnded, !impressionRecorded else { return }
                Logger.warning("ad \(id.prefix(8)): no video.start within \(Int(Self.videoStartBackstop)) s of ad.show")
                handle(.error(code: 405))
            }
        }
        DebugReporter.shared.event("ad.shown", adId: id, state: ["format": .string(format.rawValue)])
        if startMeter {
            self.startMeter()
        }
        if format == .overlay, let duration {
            // The buyer's NonLinear duration: one clock, the SDK's, counting time on screen only: it
            // freezes while the app is not active and resumes on foreground. `dismiss()` ends it earlier.
            durationRemaining = duration
            observeActivity()
            if Environment.isApplicationActive() { startDurationClock() }
        }
    }

    /// Seconds of the overlay's `duration` still to show; counted down only while the app is active.
    private var durationRemaining: TimeInterval = 0
    private var durationStartedAt: TimeInterval?
    private var activityObservers: [any NSObjectProtocol] = []

    private func startDurationClock() {
        guard durationTask == nil, !hasEnded else { return }
        let remaining = durationRemaining
        durationStartedAt = ProcessInfo.processInfo.systemUptime
        durationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000))
            guard let self, !Task.isCancelled, !hasEnded else { return }
            Logger.debug("ad \(id.prefix(8)): overlay duration of \(duration ?? 0) s on screen elapsed")
            end(.completed)
        }
    }

    private func pauseDurationClock() {
        guard let task = durationTask, let startedAt = durationStartedAt else { return }
        task.cancel()
        durationTask = nil
        durationStartedAt = nil
        durationRemaining = max(0, durationRemaining - (ProcessInfo.processInfo.systemUptime - startedAt))
        Logger.debug("ad \(id.prefix(8)): overlay clock frozen with \(durationRemaining) s left")
    }

    private func observeActivity() {
        let center = NotificationCenter.default
        activityObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseDurationClock() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.startDurationClock() }
            },
        ]
    }

    private func stopObservingActivity() {
        activityObservers.forEach(NotificationCenter.default.removeObserver)
        activityObservers = []
    }

    private var impressionRecorded = false

    private func recordImpression() {
        guard !impressionRecorded else { return }
        impressionRecorded = true
        startBackstop?.cancel()
        tracker.fire("impression")
        Logger.info("ad \(id.prefix(8)): impression")
        delegate?.videoAdDidRecordImpression(self)
    }

    /// Viewability: 50 % of the box on screen for 1 s (image) or 2 s (video) is `viewable`; the page
    /// hears every exposure change (`ad.exposure`) and pauses a video at 0.
    private func startMeter() {
        guard !hasEnded, meter == nil else { return }
        let meter = ViewabilityMeter(view: bridge.webView, requiredSeconds: ad.creative == .video ? 2 : 1)
        meter.onExposure = { [weak self] percentage, visible in
            self?.bridge.exposure(percentage: percentage, visibleRectangle: visible)
        }
        meter.onVerdict = { [weak self] verdict in
            self?.tracker.fire(verdict.rawValue)
            Logger.info("ad \(self?.id.prefix(8) ?? ""): \(verdict.rawValue)")
        }
        self.meter = meter
        meter.start()
    }

    /// The one terminal moment after a successful show. Idempotent.
    func end(_ reason: EndReason) {
        guard wasShown, !hasEnded else { return }
        hasEnded = true
        startBackstop?.cancel()
        durationTask?.cancel()
        stopObservingActivity()
        meter?.stop()
        meter = nil
        bridge.hide()
        hostView?.removeFromSuperview()
        hostView = nil
        if let controller = linearController {
            linearController = nil
            controller.isEndingByAd = true
            if controller.presentingViewController != nil, reason != .interrupted {
                controller.dismiss(animated: true)
            }
        }
        if format != .linear {
            // The ad was on screen, whatever ended it.
            tracker.fire("overlayViewDuration")
        }
        Logger.info("ad \(id.prefix(8)): ended (\(reason))")
        DebugReporter.shared.event("ad.ended", adId: id, state: ["reason": .string("\(reason)")])
        owner?.adDidEnd(self)
        delegate?.videoAd(self, didEnd: reason)
    }

    /// Opens a URL the page asked for: the app store, a deep link, a web page. The fallback is tried when
    /// the first cannot be opened (an app that is not installed).
    private func open(_ url: URL, fallback: URL?) {
        Environment.openURL(url) { opened in
            if !opened, let fallback {
                Environment.openURL(fallback) { _ in }
            }
        }
    }

    /// Resolves when the page reported `ad.loaded`; throws `creativeFailed` when it failed or timed out
    /// first, `CancellationError` when the awaiting task was cancelled (the page is stopped then).
    func awaitLoaded() async throws {
        if isLoaded { return }
        if let reason = invalidationReason, case .creativeFailed(let code) = reason { throw VideoAdError.creativeFailed(code: code) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The handler may have run before the continuation existed (a task cancelled early).
                if loadCancelled || Task.isCancelled {
                    cancelLoad()
                    continuation.resume(throwing: CancellationError())
                } else {
                    loadContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelLoad() }
        }
    }

    private var loadCancelled = false

    private func cancelLoad() {
        guard !loadCancelled, !isLoaded else { return }
        loadCancelled = true
        bridge.hide()
        Logger.debug("ad \(id.prefix(8)): load cancelled")
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    /// What the page reports, mapped to the delegate. TODO(step 4): fire the tracking entries.
    private func handle(_ event: FrameEvent) {
        switch event {
        case .loaded:
            isLoaded = true
            tracker.fire("loaded")
            loadContinuation?.resume()
            loadContinuation = nil
        case .loadFailed(let code), .error(let code):
            tracker.fire("error", errorCode: code)
            if let continuation = loadContinuation {
                loadContinuation = nil
                Logger.warning("ad \(id.prefix(8)): creative failed to load, VAST error \(code)")
                continuation.resume(throwing: VideoAdError.creativeFailed(code: code))
            } else if wasShown {
                Logger.warning("ad \(id.prefix(8)): creative failed after show, VAST error \(code)")
                delegate?.videoAd(self, didFail: .creativeFailed(code: code))
                end(.failed)
            } else {
                invalidate(.creativeFailed(code: code))
            }
        case .click(let url, let fallbackUrl, let area):
            Logger.info("ad \(id.prefix(8)): click (\(area)) \(url.host ?? url.absoluteString)")
            // The end card selects its own `click` entries; anything else is the creative's.
            tracker.fire("click", part: area == "endCard" ? "endCard" : nil)
            open(url, fallback: fallbackUrl)
            delegate?.videoAd(self, didClick: Click(url: url, area: area))
        case .open(let url, let purpose):
            Logger.info("ad \(id.prefix(8)): open (\(purpose)) \(url.host ?? url.absoluteString)")
            if purpose == "adChoices" {
                tracker.fire("iconClick")
            }
            open(url, fallback: nil)
        case .close(let reason):
            // The page's own close control; not fired for the app's dismiss() or destroy(). A linear
            // ad's close before `complete` is a skip whatever the page called it: the outcome is what
            // the app hears, and `.closed` is for the overlay and pause formats. `reason: complete` is
            // the page ending itself after the video completed with no end card: nobody closed
            // anything, so no VAST `close` fires.
            if format == .linear, !completed {
                tracker.fire("skip")
                end(.skipped)
            } else if reason == "complete" {
                end(.completed)
            } else {
                tracker.fire("close")
                end(completed ? .completed : (reason == "resume" ? .resumed : .closed))
            }
        case .skip(let playhead):
            tracker.adPlayhead = playhead
            tracker.fire("skip")
            end(.skipped)
        case .video(let name, let playhead):
            tracker.adPlayhead = playhead
            Logger.debug("ad \(id.prefix(8)): video.\(name)")
            if name == "start" {
                recordImpression()
            }
            tracker.fire(name)
        case .progress(let offset, let playhead):
            tracker.adPlayhead = playhead
            tracker.fire("progress", offset: offset)
        case .complete(let playhead):
            tracker.adPlayhead = playhead
            completed = true
            tracker.fire("complete")
            // The end card, when there is one, becomes visible now.
            tracker.fire("creativeView", part: "endCard")
            Logger.info("ad \(id.prefix(8)): complete")
            if let reward {
                delegate?.videoAd(self, didEarn: reward)
            }
        }
    }

    /// On the monotonic clock, as the SDK decides it.
    var isExpired: Bool {
        facts.isExpired
    }

    /// Timed mode: the ad has a window.
    var isWindowed: Bool {
        if case .window = trigger { return true }
        return false
    }

    /// Timed mode: the window opened and the ad is loaded; the app shows it in the callback. Once.
    func deliverWindow() {
        guard isLoaded, !wasShown, invalidationReason == nil, !windowDelivered else { return }
        if !windowReached {
            windowReached = true
            Logger.info("ad \(id.prefix(8)): window reached")
            DebugReporter.shared.event("ad.windowReached", adId: id)
        }
        // No delegate yet: the app is between `load()` returning and `ad.delegate = self`, or forgot it.
        // Delivered when the delegate is set (the property's didSet), or on the next sample.
        guard let delegate else { return }
        windowDelivered = true
        delegate.videoAdDidReachWindow(self)
    }

    /// Whether this ad still counts for its placement's one-unshown-ad rule: loading, or loaded and not
    /// yet shown. An ad on screen does not block the next load.
    var isPendingUnshown: Bool {
        !wasShown && invalidationReason == nil && !isExpired
    }

    /// A loaded, unshown ad can no longer be shown; the delegate hears why. For an ad on screen,
    /// `.destroyed` ends it instead (`didEnd(.destroyed)`).
    func invalidate(_ reason: InvalidationReason) {
        if wasShown {
            if reason == .destroyed { end(.destroyed) }
            return
        }
        guard invalidationReason == nil else { return }
        invalidationReason = reason
        RenderedAds.remove(self)
        expiryTask?.cancel()
        bridge.hide()
        Logger.debug("ad \(id.prefix(8)) invalidated: \(reason)")
        DebugReporter.shared.event("ad.invalidated", adId: id, state: ["reason": .string("\(reason)")])
        if let continuation = loadContinuation {
            // `load` was still waiting for the page: it throws instead of hanging.
            loadContinuation = nil
            continuation.resume(throwing: VideoAdError.invalidated(reason))
        } else {
            delegate?.videoAd(self, didInvalidate: reason)
        }
    }

    /// Dropping the last reference releases everything: the bridge tears the page down in its own
    /// `deinit`; the timer and the expiry task are stopped here. Never reached while the ad is on screen,
    /// because its `VideoAds` retains it until `didEnd`.
    deinit {
        expiryTask?.cancel()
        startBackstop?.cancel()
        durationTask?.cancel()
        activityObservers.forEach(NotificationCenter.default.removeObserver)
        meter?.stopTimer()
    }
}
