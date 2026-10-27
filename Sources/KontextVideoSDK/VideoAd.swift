import Foundation
import UIKit

/// One ad, from the server's answer to the end of its presentation: what `VideoAds.format(_:)` returns.
/// Look at its facts (`price`, `duration`), then `load()` it (renders the creative, so `show` is instant)
/// or `reject()` it; then `show`, the delegate's moments, and exactly one `didEnd`. An ad is shown at most
/// once; from `show` until `didEnd` the SDK retains it. A `VideoAds` holds at most one unshown ad per
/// format; `format(_:)` returns the same one until it is shown, rejected or dropped.
///
/// ```swift
/// let ad = try await ads.format(.pause)
/// if ad.price.value >= otherNetworkPrice {
///     try await ad.load()
/// } else {
///     try ad.reject(.outbid(winningPrice: otherNetworkPrice))
/// }
/// ```
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

    /// The box a creative was built for, in points. The SDK scales it down to 50 % of this when the view
    /// is smaller, and refuses to show below that. Internal: where and how big is the SDK's business.
    struct Size: Sendable, Equatable {
        let width: Int
        let height: Int
    }

    /// Where the server placed the ad.
    enum Position: Sendable, Equatable {
        case top
        case bottom
        case fullscreen
    }

    /// Why the app did not use an ad; the server tells the DSP.
    public enum RejectReason: Sendable, Equatable {
        /// The app does not use it, for any reason: the moment passed, the viewer left, the app's own choice.
        case notUsed
        /// Another network won the publisher's auction; `winningPrice` (CPM) and `winner` (the network, in
        /// the app's own words: `"AppLovin MAX"`, `"AdMob"`) when the app knows them. DSPs use both.
        case outbid(winningPrice: Double? = nil, winner: String? = nil)
    }

    /// Why an ad ended before it was shown. Found out at the next call (`format`, `load`, `show`,
    /// `reject`), which throws it; nothing is delivered through the delegate.
    public enum InvalidationReason: Sendable, Equatable {
        /// The ad's lifetime ran out (or the server replaced it, which it does only after that).
        case expired
        /// The app called `reject()`.
        case rejected
        /// The `VideoAds` was destroyed.
        case destroyed
        /// The creative failed to load, or died while the ad waited to be shown (for example the web
        /// content process was terminated). `code` is the VAST error code the SDK fired.
        case creativeFailed(code: Int)
    }

    /// The facts an app decides on before rendering. Where the ad goes and how big it is are the SDK's
    /// business at `show`; nothing of that is exposed.
    public var id: String { descriptor.id }
    public var format: AdFormat { descriptor.format }
    public var price: Price { descriptor.price }
    /// Overlay: how long the SDK keeps it on screen, `nil` when it stays until the app ends it. Linear:
    /// the video's length. Seconds; always `nil` for a pause ad.
    public var duration: TimeInterval? { descriptor.duration }
    /// The size variant `show` chose for the view: the largest that fits without scaling, else the one
    /// with the best scale still at or above 50 %.
    private(set) var chosenSize: Size?

    /// The page reported the creative ready: `load()` finished.
    public private(set) var isLoaded = false

    /// Whether `show` can be called: the creative is loaded, the ad was not shown yet and not invalidated.
    /// A hint for "show or load" decisions, not the authority: the box is measured only at `show`, and
    /// `show` throws when it cannot begin.
    public var isReady: Bool {
        isLoaded && !wasShown && invalidationReason == nil && !isExpired
    }

    /// Why the ad ended before it was shown, once it did; `load()`, `show` and `reject()` throw it.
    public private(set) var invalidationReason: InvalidationReason?
    /// On the monotonic clock, as the SDK decides it.
    var isExpired: Bool {
        descriptor.isExpired
    }

    /// Receives the ad's moments. Held weakly.
    public weak var delegate: (any VideoAdDelegate)?

    /// `true` from a successful `show` on; an ad is shown at most once.
    public private(set) var wasShown = false
    /// `true` once the ad began to end. For an overlay or pause ad the creative is already gone and `didEnd`
    /// follows at once; a linear ad may still be dismissing, and `didEnd` follows once that finished.
    public private(set) var hasEnded = false
    /// Whether the creative ran to its end: a video reached `complete`, an
    /// overlay's `duration` elapsed. Separate from `didEnd`'s reason, which says how the ad left the
    /// screen: a linear ad whose end card the viewer closed ends `.closed` with this `true`.
    public private(set) var isCompleted = false

    /// Below this share of the nominal size the ad is not shown.
    static let minimumScale: CGFloat = 0.5

    /// The server's answer this ad renders; the expiry counts from the first receipt, a re-serve does not
    /// move it.
    let descriptor: AdDescriptor
    /// The WebView and the protocol with the frame page. Made on the first `load()`, never before: an ad
    /// the app only looks at, or rejects, costs no WebView.
    var bridge: FrameBridge {
        if let loadedBridge { return loadedBridge }
        let bridge = FrameBridge(adId: descriptor.id, url: descriptor.frameURL, isVideo: descriptor.creative == .video)
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        loadedBridge = bridge
        return bridge
    }
    private(set) var loadedBridge: FrameBridge?
    /// The load in flight, shared by every `load()` call: the second waits for the first.
    private var loading: Task<Void, Error>?
    /// `load` waiting for the page.
    private var loadContinuation: CheckedContinuation<Void, Error>?
    /// The `VideoAds` it belongs to; told when the ad leaves it, is shown, and ends.
    private(set) weak var owner: VideoAds?
    /// The view the SDK put into the player's view for an overlay or pause ad.
    private var hostView: UIView?
    /// The controller the SDK presented for a linear ad.
    private(set) var linearController: LinearViewController?
    /// The creative is on screen: the page was told to show, the beacons of that moment fired. At `show`
    /// for an overlay or pause ad; for a linear ad once UIKit presented the controller.
    private(set) var isPresented = false
    /// `didEnd` was delivered. For a linear ad that is after its dismissal, so this lags `hasEnded`.
    private var finished = false
    /// Fires the `tracking` entries, each once: `notUsed` before anything is rendered, the rest on screen.
    let tracker: Tracker
    /// Decides `viewable` / `notViewable` while the ad is on screen.
    private(set) var meter: ViewabilityMeter?
    /// The ad video is playing (from `video.start`, not while paused, over at `complete`): the only time a
    /// video creative's viewability clock runs. Kept here because the meter may not exist yet when the
    /// video starts: a linear ad's meter waits for the presentation to finish.
    private var videoPlaying = false
    /// Removes an overlay when its `duration` elapses; the app runs no timer.
    private(set) var durationTask: Task<Void, Never>?
    /// When the current stretch of active time on screen began; `nil` while the app is not active.
    private var activeSince: TimeInterval?
    /// Active time on screen before the current stretch, seconds.
    private var activeAccumulated: TimeInterval = 0
    /// `nonisolated(unsafe)` only so `deinit`, which is not on the main actor, may read it for the teardown.
    nonisolated(unsafe) private(set) var activityObservers: [any NSObjectProtocol] = []
    /// Seconds the ad has been on screen while the app was active.
    var activeTimeOnScreen: TimeInterval {
        activeAccumulated + (activeSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }
    /// The impression fires once: at `show` for an image, at the first frame for a video.
    private var impressionRecorded = false

    /// Nothing is rendered here; `load()` does that. Expiry is checked at the next call, never by a timer.
    init(descriptor: AdDescriptor, owner: VideoAds) {
        self.descriptor = descriptor
        self.owner = owner
        tracker = Tracker(adId: descriptor.id, entries: descriptor.tracking)
        tracker.contentPlayhead = { [weak owner] in owner?.playhead ?? 0 }
    }

    // MARK: Loading and rejecting

    /// Renders the creative, so that `show` is instant: the SDK creates a WebView with the ad's page and
    /// waits until the page reports the creative ready. Calls made while a load runs share it and get the
    /// same outcome; a call after it returns at once, nothing is rendered twice. Throws
    /// `creativeFailed(code:)` when the creative fails or does not report ready within 10 s of active
    /// time, `invalidated(.expired)` once the ad's lifetime ran out (before or during the load),
    /// `invalidated(.rejected)` after `reject()`, `destroyed`, `disabled(reason:)`, or `CancellationError`
    /// when the calling task is cancelled (the load itself continues).
    public func load() async throws {
        try checkUsable()
        if isLoaded, loading == nil { return }
        let task = loading ?? startLoading()
        try await awaitShared(task)
    }

    /// The app does not use the ad: the SDK sends the `notUsed` beacon (the server tells the DSP), drops the
    /// ad and releases its WebView, if any. Works until `show`, loading or loaded; a `load()` in flight
    /// throws `invalidated(.rejected)`, a later `show` too. Synchronous and fire-and-forget. Throws
    /// `alreadyShown` after `show`, `invalidated(reason)` or `destroyed` when the ad already ended.
    public func reject(_ reason: RejectReason = .notUsed) throws {
        if wasShown { throw VideoAdError.alreadyShown }
        if let invalidationReason { throw Self.error(for: invalidationReason) }
        if descriptor.isExpired {
            invalidate(.expired)
            throw VideoAdError.invalidated(.expired)
        }
        Logger.info("\(format) ad \(id.prefix(8)): rejected (\(reason))")
        tracker.fire("notUsed", notUsed: Tracker.NotUsed(reason))
        invalidate(.rejected)
    }

    /// The ad can still be loaded or shown; otherwise the error to throw.
    func checkUsable() throws {
        guard let owner, !owner.isDestroyed else { throw VideoAdError.destroyed }
        if let reason = KontextVideo.shared.disabledReason { throw VideoAdError.disabled(reason: reason) }
        if let invalidationReason { throw Self.error(for: invalidationReason) }
        if descriptor.isExpired {
            invalidate(.expired)
            throw VideoAdError.invalidated(.expired)
        }
    }

    /// The load belongs to the ad, not to the caller: an unstructured task nobody cancels. Only
    /// `invalidate` stops it, by failing the wait for the page.
    private func startLoading() -> Task<Void, Error> {
        bridge.load()
        let task = Task { [weak self] () throws in
            defer { self?.loading = nil }
            guard let self else { throw VideoAdError.destroyed }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try await awaitLoaded()
            } catch VideoAdError.creativeFailed(let code) {
                invalidate(.creativeFailed(code: code))
                DebugReporter.shared.event("ad.loadFailed", adId: id, level: .warning, state: ["code": .number(Double(code))])
                throw VideoAdError.creativeFailed(code: code)
            } catch {
                // The ad ended meanwhile: say why in the order the app expects (destroyed, disabled, rejected, ...).
                try checkUsable()
                throw error
            }
            // Expired while the page loaded: the result is dropped.
            try checkUsable()
            let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            Logger.info("\(format) ad \(id.prefix(8)): ready in \(durationMs) ms")
            DebugReporter.shared.event("ad.loaded", adId: id, state: ["durationMs": .number(Double(durationMs))])
        }
        loading = task
        return task
    }

    // MARK: Showing

    /// Shows an overlay or pause ad inside `view`, the one the content plays in (the view that fills the
    /// video area, not the screen), at the ad's `position` and `size`; a full-screen pause ad fills it.
    /// Throws when presentation cannot begin, with nothing fired: `wrongPresentation` (a linear ad),
    /// `alreadyShown`, `anotherAdShowing`, `invalidated`, `destroyed`, `disabled`, `presenterUnavailable`
    /// (the view is not on screen) and `containerTooSmall` (the ad stays ready in both). Succeeds once the ad is on screen; from then until `didEnd` the SDK retains it.
    public func show(in view: UIView) throws {
        guard format != .linear else { throw VideoAdError.wrongPresentation }
        try checkShowable()
        guard view.window != nil else {
            Logger.warning("ad \(id.prefix(8)): cannot show, the view is not on screen")
            throw VideoAdError.presenterUnavailable
        }
        let container = view
        let host = UIView(frame: try frame(in: container.bounds))
        host.autoresizingMask = descriptor.position == .fullscreen ? [.flexibleWidth, .flexibleHeight] : [.flexibleLeftMargin, .flexibleRightMargin, descriptor.position == .top ? .flexibleBottomMargin : .flexibleTopMargin]
        let webView = bridge.takeWebView()
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(webView)
        container.addSubview(host)
        hostView = host
        bridge.chosenSize = chosenSize.map { ($0.width, $0.height) }
        begin()
    }

    /// Presents a linear ad full screen. From `viewController` when given, which must be on screen
    /// and not already presenting; with `nil` (the default) from the key window's top view controller,
    /// as AdMob's `present(from: nil)` and MAX's `showAd()` do. Pass the controller when the guess would
    /// be wrong: a player presented as a sheet, a second window, a hosting controller that is not yours.
    /// Throws when presentation cannot begin, with nothing fired: `wrongPresentation` (an overlay or pause
    /// ad), `alreadyShown`, `anotherAdShowing`, `invalidated`, `destroyed`, `disabled`,
    /// `presenterUnavailable` (the ad stays ready; try again later or pass the right controller). Only the
    /// SDK dismisses it: the video completing, a skip, a close, an error, or an interruption, each ending
    /// in one `didEnd`. From here until `didEnd` the SDK retains the ad.
    public func show(from viewController: UIViewController? = nil) throws {
        guard format == .linear else { throw VideoAdError.wrongPresentation }
        try checkShowable()
        let presenter: UIViewController
        if let viewController {
            guard viewController.view.window != nil, viewController.presentedViewController == nil,
                  !viewController.isBeingPresented, !viewController.isBeingDismissed else {
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
        // The page is shown, and the beacons of that moment fire, once UIKit confirms the presentation:
        // an ad UIKit refused must never record an impression.
        presenter.present(controller, animated: true) { [weak self] in
            self?.presented()
        }
        begin(presentNow: false)
        // UIKit can refuse a presentation without an error (another one in progress); then the completion
        // never runs and the ad would hold the screen forever. After `presentationTimeout`: a controller
        // that never reached a window failed; one that did, without the completion, is taken as presented
        // after a longer wait.
        Task { [weak self] in
            let step = min(Self.presentationTimeout, 0.25)
            let deadline = Environment.now() + Self.presentationTimeout
            let cap = Environment.now() + Self.presentationTimeout * 5
            while let ad = self, !ad.hasEnded, !ad.isPresented, Environment.now() < cap {
                if Environment.now() >= deadline, controller.view.window == nil { break }
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            }
            guard let self, !hasEnded, !isPresented else { return }
            if controller.view.window != nil {
                Logger.warning("ad \(id.prefix(8)): UIKit never confirmed the presentation, but the controller is on screen; taken as presented")
                presented()
            } else {
                Logger.error("ad \(id.prefix(8)): UIKit did not present the linear ad; ended as failed")
                delegate?.videoAd(self, didFail: .presenterUnavailable)
                end(.failed)
            }
        }
    }

    /// How long a linear presentation may take to reach the screen before the ad gives up on it.
    static var presentationTimeout: TimeInterval = 2
    /// How long a linear dismissal may take before `didEnd` is delivered anyway, once the controller has
    /// left the screen (five times that if it has not): a completion UIKit never calls must not keep the
    /// app waiting, and a dismissal still running must not be reported over.
    static var dismissalTimeout: TimeInterval = 1

    /// The key window's root controller, followed through what it presents to the top, as the peers do
    /// (AdMob 11, MAX). `nil` when there is no key window or the top controller cannot present: it is
    /// being dismissed or is mid-transition; a system alert or sheet on top is a plain controller that
    /// can, and the ad goes over it, as a peer's would.
    static func topViewController() -> UIViewController? {
        guard var controller = Environment.keyWindow()?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        // Still presenting (its modal is mid-dismissal), or mid-transition itself: UIKit would refuse.
        guard controller.view.window != nil, controller.presentedViewController == nil,
              !controller.isBeingPresented, !controller.isBeingDismissed else { return nil }
        return controller
    }

    /// Ends an overlay or pause ad because the app says so: the page is removed, `overlayViewDuration`
    /// fires, and the delegate gets `didEnd(.dismissed)`. Terminal; the ad cannot be shown again. For an
    /// overlay with a `duration` this is the way to end it earlier (the content ended, a seek); left alone,
    /// the SDK removes it when the duration elapses, with `didEnd(.completed)`. An overlay without one,
    /// like a pause ad, stays until this, the viewer's close control or `destroy()`. Before `show` and
    /// after `didEnd` it does nothing. Throws `wrongPresentation` for a linear ad: it ends by itself or by
    /// the viewer's Skip or close; `destroy()` is the way to force it off.
    public func dismiss() throws {
        guard format != .linear else { throw VideoAdError.wrongPresentation }
        guard wasShown, !hasEnded else { return }
        Logger.debug("ad \(id.prefix(8)): dismissed by the app")
        end(.dismissed)
    }

    private func checkShowable() throws {
        if wasShown { throw VideoAdError.alreadyShown }
        try checkUsable()
        if KontextVideo.shared.adOnScreen != nil { throw VideoAdError.anotherAdShowing }
        guard isLoaded else { throw VideoAdError.notLoaded }
    }

    /// Where the ad goes in the player's view: the best variant for the box, scaled down to fit, never
    /// below 50 %. Picks the variant first (the largest that fits without scaling, else the best scale),
    /// so a player that changed shape between `load` and `show` gets the size built for it.
    private func frame(in bounds: CGRect) throws -> CGRect {
        guard descriptor.position != .fullscreen, let defaultSize = descriptor.size else { return bounds }
        func fit(_ candidate: Size) -> CGFloat {
            min(1, bounds.width / CGFloat(candidate.width), bounds.height / CGFloat(candidate.height))
        }
        let unscaled = descriptor.sizes.filter { fit($0) >= 1 }
        let size = unscaled.max { $0.width * $0.height < $1.width * $1.height }
            ?? descriptor.sizes.max { fit($0) < fit($1) }
            ?? defaultSize
        chosenSize = size
        if size != defaultSize { Logger.debug("ad \(id.prefix(8)): size \(size.width)\u{00D7}\(size.height) chosen for a \(Int(bounds.width))\u{00D7}\(Int(bounds.height)) view") }
        let nominal = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
        let scale = fit(size)
        guard scale >= Self.minimumScale else {
            let minimum = CGSize(width: (nominal.width * Self.minimumScale).rounded(.up), height: (nominal.height * Self.minimumScale).rounded(.up))
            Logger.warning("ad \(id.prefix(8)): view \(Int(bounds.width))×\(Int(bounds.height)) is below 50 % of the ad's \(size.width)×\(size.height); the ad stays ready")
            chosenSize = nil
            throw VideoAdError.containerTooSmall(minimum: minimum)
        }
        let scaled = CGSize(width: (nominal.width * scale).rounded(), height: (nominal.height * scale).rounded())
        let x = ((bounds.width - scaled.width) / 2).rounded()
        let y = descriptor.position == .top ? 0 : bounds.height - scaled.height
        return CGRect(x: x, y: y, width: scaled.width, height: scaled.height)
    }

    /// `show` committed: the ad takes the app's one slot, the SDK retains it, it leaves its `VideoAds`'s
    /// unshown ones; `show` returning is the app's signal. The creative itself goes on screen in
    /// `presented()`: at once for an overlay or pause ad, once UIKit confirmed it for a linear ad.
    private func begin(presentNow: Bool = true) {
        wasShown = true
        KontextVideo.shared.adOnScreen = self
        owner?.adDidBeginShowing(self)
        Logger.info("ad \(id.prefix(8)): shown")
        DebugReporter.shared.event("ad.shown", adId: id, state: ["format": .string(format.rawValue)])
        if presentNow { presented() }
    }

    /// The creative is on screen: the page is told, the meter and the clocks run, the beacons of the moment
    /// fire. Everything the ad needs while on screen is set up before anyone outside hears of it: the
    /// impression delegate at the end may end the ad on the spot, and `end()` must find all of it.
    func presented() {
        guard !hasEnded, !isPresented else { return }
        isPresented = true
        bridge.show()
        startMeter()
        if format != .linear {
            // Time on screen while the app is active: `overlayViewDuration` reports it, and an overlay's
            // `duration` runs on it, so both freeze in the background and resume on foreground.
            observeActivity()
            if Environment.isApplicationActive() { beginActiveStretch() }
        }
        // At `ad.show`: creativeView and the AdChoices icon's view; the impression too for an image or
        // HTML creative, while a video's waits for its first frame. A video's impression waits for
        // `video.start`. The page owns the start timeout (3 s, then `ad.error` 405) and, when autoplay
        // was refused, waits for the viewer's tap as long as it takes; the SDK keeps no start timer, it
        // could not tell the two apart.
        tracker.fire("creativeView")
        tracker.fire("iconView")
        if descriptor.creative != .video {
            recordImpression()
        }
    }

    /// The buyer's NonLinear `duration`, counted on active time only. `dismiss()` ends it earlier.
    private func startDurationClock() {
        guard durationTask == nil, !hasEnded, let duration else { return }
        // Clamped to a day: a nonsense server value must not trap the `UInt64` conversion.
        let remaining = min(max(0, duration - activeTimeOnScreen), 86_400)
        durationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, !Task.isCancelled, !hasEnded else { return }
            Logger.debug("ad \(id.prefix(8)): overlay duration of \(duration) s on screen elapsed")
            isCompleted = true
            end(.completed)
        }
    }

    private func applicationDidResignActive() {
        if let since = activeSince {
            activeAccumulated += ProcessInfo.processInfo.systemUptime - since
            activeSince = nil
        }
        durationTask?.cancel()
        durationTask = nil
        Logger.debug("ad \(id.prefix(8)): clock frozen at \(activeAccumulated) s on screen")
    }

    private func applicationDidBecomeActive() {
        guard !hasEnded, activeSince == nil else { return }
        beginActiveStretch()
    }

    /// The app is active and the ad on screen: the clocks run from now.
    private func beginActiveStretch() {
        activeSince = ProcessInfo.processInfo.systemUptime
        if format == .overlay, duration != nil { startDurationClock() }
    }

    private func observeActivity() {
        let center = NotificationCenter.default
        activityObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidResignActive() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
            },
        ]
    }

    private func stopObservingActivity() {
        activityObservers.forEach(NotificationCenter.default.removeObserver)
        activityObservers = []
    }

    private func recordImpression() {
        guard !impressionRecorded else { return }
        impressionRecorded = true
        tracker.fire("impression")
        Logger.info("ad \(id.prefix(8)): impression")
        delegate?.videoAdDidRecordImpression(self)
    }

    /// Viewability: 50 % of the box on screen for 1 s (image) or 2 s (video) is `viewable`; the page
    /// hears every exposure change (`ad.exposure`) and pauses a video at 0.
    private func startMeter() {
        guard !hasEnded, meter == nil else { return }
        let meter = ViewabilityMeter(view: bridge.webView, requiredSeconds: descriptor.creative == .video ? 2 : 1)
        // MRC: two seconds of the video *played*. Exposure is measured from show, for the page; the
        // viewability clock runs only while the video plays (from `video.start`, not while paused).
        meter.countsTime = descriptor.creative != .video || videoPlaying
        meter.onExposure = { [weak self] percentage, visible in
            self?.bridge.exposure(percentage: percentage, visibleRectangle: visible)
        }
        meter.onVerdict = { [weak self] verdict in
            self?.tracker.fire(verdict.rawValue)
            Logger.info("ad \(self?.id.prefix(8) ?? ""): \(verdict.rawValue)")
        }
        // The app took the view away under the ad (navigated off without dismiss()): the ad is gone
        // from the screen, so it ends, as a linear ad does when its controller is dismissed from outside.
        // Otherwise it would stay the ad on screen and block every show in the app.
        meter.onDetached = { [weak self] in
            guard let self else { return }
            Logger.warning("ad \(id.prefix(8)): its view left the window; ended as interrupted")
            end(.interrupted)
        }
        self.meter = meter
        meter.start()
    }

    /// The one terminal moment after a successful show. Idempotent.
    func end(_ reason: EndReason) {
        guard wasShown, !hasEnded else { return }
        hasEnded = true
        durationTask?.cancel()
        stopObservingActivity()
        meter?.stop()
        meter = nil
        loadedBridge?.hide()
        loadedBridge = nil   // an ended ad keeps its facts, not a WebView
        hostView?.removeFromSuperview()
        hostView = nil
        var dismissing = false
        if let controller = linearController {
            linearController = nil
            controller.isEndingByAd = true
            if controller.presentingViewController != nil, reason != .interrupted {
                // `didEnd` waits for the dismissal, as AdMob's and MAX's "dismissed" callbacks do: an app
                // that presents its next screen in `didEnd` must not collide with the animation.
                dismissing = true
                controller.dismiss(animated: true) { [weak self] in self?.finish(reason) }
                // A completion UIKit never calls: once the controller has left the screen, or after a
                // hard cap while it still has not, the app hears `didEnd` anyway.
                Task { [weak self] in
                    let deadline = Environment.now() + Self.dismissalTimeout
                    let cap = Environment.now() + Self.dismissalTimeout * 5
                    repeat {
                        try? await Task.sleep(nanoseconds: UInt64(min(Self.dismissalTimeout, 0.25) * 1_000_000_000))
                    } while Environment.now() < deadline || (controller.view.window != nil && Environment.now() < cap)
                    guard let self, !finished else { return }
                    if controller.view.window != nil {
                        // Reported over a controller UIKit did not take down: the app is not kept waiting, and the log says so.
                        Logger.error("ad \(id.prefix(8)): the linear ad's dismissal did not finish in \(Int(Self.dismissalTimeout * 5)) s; didEnd delivered anyway")
                        DebugReporter.shared.event("ad.dismissalTimedOut", adId: id, level: .warning)
                    }
                    finish(reason)
                }
            }
        }
        if format != .linear {
            // The ad was on screen, whatever ended it; `[KONTEXT_VIEWDURATION]` is the active time, not the wall clock.
            if let since = activeSince {
                activeAccumulated += ProcessInfo.processInfo.systemUptime - since
                activeSince = nil
            }
            tracker.fire("overlayViewDuration", viewDurationMs: Int((activeAccumulated * 1000).rounded()))
        }
        Logger.info("ad \(id.prefix(8)): ended (\(reason))")
        DebugReporter.shared.event("ad.ended", adId: id, state: ["reason": .string("\(reason)")])
        if !dismissing { finish(reason) }
    }

    /// The screen is free and the app hears `didEnd`: at once for an overlay or pause ad, once the
    /// dismissal finished for a linear ad. Once.
    private func finish(_ reason: EndReason) {
        guard !finished else { return }
        finished = true
        if KontextVideo.shared.adOnScreen === self { KontextVideo.shared.adOnScreen = nil }
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
    /// first, the invalidation when the ad ended meanwhile (rejected, destroyed). Called once, by the load
    /// task, which nobody cancels.
    private func awaitLoaded() async throws {
        if isLoaded { return }
        if case .creativeFailed(let code)? = invalidationReason { throw VideoAdError.creativeFailed(code: code) }
        if let reason = invalidationReason { throw Self.error(for: reason) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
        }
    }

    /// What the page reports, mapped to the beacons and the delegate.
    private func handle(_ event: FrameEvent) {
        // The bridge stops delivering once hidden; this is the same rule at the ad's own door.
        guard !hasEnded, invalidationReason == nil else { return }
        switch event {
        case .loaded:
            isLoaded = true
            tracker.fire("loaded")
            loadContinuation?.resume()
            loadContinuation = nil
        case .error(let code):
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
                // Died while waiting to be shown: the ad ends; `show` will throw.
                invalidate(.creativeFailed(code: code))
            }
        case .click(let url, let fallbackUrl, let area):
            Logger.info("ad \(id.prefix(8)): click (\(area)) \(url.host ?? url.absoluteString)")
            // The end card selects its own `click` entries; anything else is the creative's.
            // One occurrence: the beacon and the click-through carry the same fire id (Tracking Events page).
            let fireId = tracker.fire("click", part: area == .endCard ? "endCard" : nil)
            open(tracker.clickThrough(url, fireId: fireId), fallback: fallbackUrl.map { tracker.clickThrough($0, fireId: fireId) })
            delegate?.videoAd(self, didClick: Click(url: url, area: area))
        case .open(let url, let purpose):
            Logger.info("ad \(id.prefix(8)): open (\(purpose)) \(url.host ?? url.absoluteString)")
            if purpose == "adChoices" {
                tracker.fire("iconClick")
            }
            open(url, fallback: nil)
        case .close(let reason):
            // The page's own close control; not fired for the app's dismiss() or destroy(). The reason is
            // the gesture, the same in every format; `isCompleted` says whether the video ran to its
            // end. A linear ad's close before `complete` is a skip. `reason: complete` is the page ending
            // itself after the video completed with no end card: nobody closed anything, so no VAST
            // `close` fires.
            if format == .linear, !isCompleted {
                tracker.fire("skip")
                end(.skipped)
            } else {
                switch reason {
                case .complete:
                    end(.completed)
                case .resume:
                    tracker.fire("close")
                    end(.resumed)
                case .close:
                    tracker.fire("close")
                    end(.closed)
                }
            }
        case .skip(let playhead):
            tracker.adPlayhead = playhead
            tracker.fire("skip")
            end(.skipped)
        case .video(let event, let playhead):
            tracker.adPlayhead = playhead
            Logger.debug("ad \(id.prefix(8)): video.\(event.rawValue)")
            switch event {
            case .start, .resume: videoPlaying = true
            case .pause: videoPlaying = false
            default: break
            }
            meter?.countsTime = videoPlaying
            tracker.fire(event.rawValue)
            tracker.fireProgress(upTo: playhead)
            // The delegate last: it may end the ad on the spot, and everything above was the event's own.
            if event == .start {
                recordImpression()
            }
        case .progress(let offset, let playhead):
            tracker.adPlayhead = playhead
            tracker.fireProgress(upTo: max(offset, playhead))
        case .complete(let playhead):
            tracker.adPlayhead = playhead
            isCompleted = true
            videoPlaying = false
            meter?.countsTime = false   // the end card is not the video playing
            // Checkpoints before the end that the page never reported, then the end itself.
            tracker.fireProgress(upTo: playhead)
            tracker.fire("complete")
            // The end card, when there is one, becomes visible now.
            tracker.fire("creativeView", part: "endCard")
            Logger.info("ad \(id.prefix(8)): complete")
        }
    }

    /// The ad ends before `show`: it leaves its `VideoAds` (never served again), its WebView is released,
    /// a `load()` in flight throws. For an ad on screen nothing happens; `destroy()` ends that one with
    /// `didEnd(.destroyed)`. No beacon here: `reject` and `destroy` fire `notUsed` themselves, an expired
    /// ad is the server's to close, a failed creative already fired `error`.
    func invalidate(_ reason: InvalidationReason) {
        guard !wasShown, invalidationReason == nil else { return }
        invalidationReason = reason
        Logger.debug("\(format) ad \(id.prefix(8)) ended before show: \(reason)")
        DebugReporter.shared.event("ad.invalidated", adId: id, state: ["reason": .string("\(reason)")])
        loadedBridge?.hide()
        loadedBridge = nil
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(throwing: Self.error(for: reason))
        }
        owner?.adDidLeave(self)
    }

    static func error(for reason: InvalidationReason) -> VideoAdError {
        reason == .destroyed ? .destroyed : .invalidated(reason)
    }

    /// Dropping the last reference releases everything: the bridge tears the page down in its own
    /// `deinit`; the duration clock is stopped here. Never reached while the ad is on screen, because the
    /// SDK retains it until `didEnd`.
    deinit {
        let clock = durationTask
        let observers = activityObservers
        let meter = self.meter
        let teardown: @MainActor () -> Void = {
            clock?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
            meter?.stopTimer()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            Task { @MainActor in teardown() }
        }
    }
}
