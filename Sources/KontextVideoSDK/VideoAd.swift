import Foundation
import UIKit

/// One ad, from the server's answer to the end of its time on screen: what `VideoAds.format(_:)` returns.
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
///     ad.reject(.outbid(winningPrice: otherNetworkPrice))
/// }
/// ```
///
/// One type serves every format, so `format(_:)` and an auction read the same way for all three; the format
/// decides how it is shown: `show(in:)` for an overlay or pause ad, `show(from:)` for a linear ad. The
/// other call is a programmer error, caught at that call: it stops a debug build and throws
/// `wrongPresentation` in a release build. Code that shows an ad of a format it does not fix switches on
/// `format`.
///
/// ## State
///
/// The public flags move one way and only in these combinations; any other is impossible:
///
/// | Stage | `isLoaded` | `isReady` | `invalidationReason` | `wasShown` | `hasEnded` |
/// |---|---|---|---|---|---|
/// | Returned by `format(_:)` | `false` | `false` | `nil` | `false` | `false` |
/// | Loaded | `true` | `true`, `false` once expired | `nil` | `false` | `false` |
/// | Ended before `show` | as it was | `false` | set | `false` | `false` |
/// | On screen | `true` | `false` | `nil` | `true` | `false` |
/// | Ended after `show` | `true` | `false` | `nil` | `true` | `true` |
///
/// - `invalidationReason` and `wasShown` never are both set: an ad ends either before `show` (nothing is
///   delivered) or after it (exactly one `didEnd`). `hasEnded` implies `wasShown`.
/// - Expiry is found at the next call: an expired ad reads `isReady == false` with `invalidationReason`
///   still `nil` until `load()`, `show`, `reject()` or the next `format(_:)` sets it to `.expired`.
/// - `isCompleted` can be `true` only once shown, and may be `true` before `hasEnded`: a linear ad's
///   video completed and its end card is still on screen.
/// - A linear ad's `hasEnded` comes when it begins to end; `didEnd` follows once its dismissal finished.
@MainActor
public final class VideoAd {
    // Format differences. One type serves the three formats; what differs lives in two places, chosen once
    // per ad, so this class asks "which format?" only for the public guards and the linear facts below:
    //
    //   how it follows the content   ContentRule   OverlayRule / PauseRule / NoContentRule (linear)
    //   where it is on screen        AdScreen      InlineScreen (overlay, pause) / LinearScreen (linear)
    //
    // This class keeps what every format shares: show's checks, the page's events and beacons, and the
    // one terminal path, end(_:) then finish(_:). Rules and screens end an ad only through end(_:).
    //
    // The rest of VideoAd lives in:
    //
    //   Frame/VideoAd+FrameEvents.swift    handle, handleNow: what the ad does with each message of its page
    //   Frame/VideoAd+Click.swift          click, openClick, open: a click's beacon, delegate and URL
    //   Screen/VideoAd+Placement.swift     frame(in:), refit, tooSmall, fullscreenFrame: where the ad goes
    //   VideoAd+Types.swift                its value types: Price, RejectReason, InvalidationReason, Size, Position
    //   VideoAd+Errors.swift               the errors show and load throw, and the creative's error report
    //   Model/AdState.swift                every fact of its life: its phase, milestones and flags
    //   Model/AdLifecycle.swift            the phases and the legal moves between them

    // The facts an app decides on before rendering. Where the ad goes and how big it is are the SDK's
    // business at `show`; nothing of that is exposed.

    /// The server's id of this ad: unique per auction win, the same while the server re-serves it.
    public var id: String { descriptor.id }
    /// Which moment the ad is for: `.pause`, `.overlay` or `.linear`.
    public var format: AdFormat { descriptor.format }
    /// What the ad pays, for the app's own auction against other networks.
    public var price: Price { descriptor.price }
    /// Overlay: how long the SDK keeps it on screen, `nil` when it stays until the app ends it. Linear:
    /// the video's length. Seconds; always `nil` for a pause ad.
    public var duration: TimeInterval? { descriptor.duration }
    /// The size variant `show` chose for the view: the largest that fits without scaling, else the one
    /// with the best scale still at or above 50 %.
    var chosenSize: Size?

    /// The page reported the creative ready: `load()` finished.
    public var isLoaded: Bool { state.isLoaded }

    /// Whether `show` can be called: the creative is loaded, the ad was not shown yet and not invalidated, and
    /// the server has not switched the SDK off.
    /// A hint for "show or load" decisions, not the authority: the box is measured only at `show`, and
    /// `show` throws when it cannot begin.
    public var isReady: Bool {
        isLoaded && !wasShown && invalidationReason == nil && !isExpired && KontextVideo.shared.disabledReason == nil
    }

    /// Why the ad ended before it was shown, once it did; `load()` and `show` throw it.
    public var invalidationReason: InvalidationReason? {
        state.invalidationReason
    }
    /// On the monotonic clock, as the SDK decides it.
    var isExpired: Bool {
        descriptor.isExpired
    }

    /// Receives the ad's moments. Held weakly.
    public weak var delegate: (any VideoAdDelegate)?

    /// `true` from a successful `show` on; an ad is shown at most once.
    public var wasShown: Bool {
        state.wasShown
    }
    /// `true` once the ad began to end. For an overlay or pause ad the creative is already gone and `didEnd`
    /// follows at once; a linear ad may still be dismissing, and `didEnd` follows once that finished.
    public var hasEnded: Bool {
        state.hasEnded
    }
    /// Whether the creative ran to its end: a video reached `complete`, an
    /// overlay's `duration` elapsed. Separate from `didEnd`'s reason, which says how the ad left the
    /// screen: a linear ad whose end card the viewer closed ends `.closed` with this `true`.
    public var isCompleted: Bool { state.isCompleted }

    /// Every fact of the ad's life, the one source of truth: every public flag above reads it live. The phase
    /// moves only forward, through `state.moveTo(_:)` under `AdLifecycle`'s rules; each milestone is marked once,
    /// `wasOnScreen` too: at `show` for an overlay or pause ad, once UIKit presented the controller for a linear ad
    /// (`Model/AdState.swift`).
    var state = AdState()

    /// The server's answer this ad renders; the expiry counts from the first receipt, a re-serve does not
    /// move it.
    let descriptor: AdDescriptor
    /// The WebView and the protocol with the frame page. Made on the first `load()`, never before: an ad
    /// the app only looks at, or rejects, costs no WebView.
    var bridge: FrameBridge {
        if let loadedBridge { return loadedBridge }
        // A linear ad's duration is its video's length; an overlay's is its time on screen, not the video's.
        // A fact of the linear format, not of its screen.
        let bridge = FrameBridge(adId: descriptor.id, url: descriptor.frameURL, isVideo: descriptor.creative == .video,
                                 videoDuration: descriptor.format == .linear ? descriptor.duration : nil)
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        loadedBridge = bridge
        return bridge
    }
    private(set) var loadedBridge: FrameBridge?
    /// The load in flight, shared by every `load()` call: the second waits for the first.
    private var loading: Task<Void, Error>?
    /// `load` waiting for the page.
    var loadContinuation: CheckedContinuation<Void, Error>?
    /// The `VideoAds` it belongs to; told when the ad leaves it, is shown, and ends.
    private(set) weak var owner: VideoAds?
    /// The ad on screen, from `show` to `didEnd`: the slot, the host view or controller, the meter, the clock.
    private(set) var shownAd: ShownAd?
    /// The app's insets from `show(in:insets:)`, on top of the view's safe area, for every refit too.
    var extraInsets = UIEdgeInsets.zero
    /// Fires the `tracking` entries, each once: `notUsed` before anything is rendered, the rest on screen.
    let tracker: Tracker
    var meter: ViewabilityMeter? { shownAd?.meter }
    /// The ad video is playing (from `video.start`, not while paused, over at `complete`): the only time a
    /// video creative's viewability clock runs. Kept here because the meter may not exist yet when the
    /// video starts: a linear ad's meter waits for the presentation to finish.
    var isVideoPlaying = false
    var clock: ActiveTimeClock? { (shownAd?.screen as? InlineScreen)?.clock }
    /// How the ad follows the tracked content player, by format (`Playback/ContentRule.swift`). Made on first
    /// use: it holds the ad, which `init` cannot hand out.
    private(set) lazy var contentRule: any ContentRule = makeContentRule(for: self)
    /// Apple's install attribution of an app-install ad; `nil` for every other ad.
    private(set) var skAdNetwork: SKAdNetworkImpression?

    /// Nothing is rendered here; `load()` does that. Expiry is checked at the next call, never by a timer.
    init(descriptor: AdDescriptor, owner: VideoAds) {
        self.descriptor = descriptor
        self.owner = owner
        tracker = Tracker(adId: descriptor.id, entries: descriptor.tracking)
        tracker.contentPlayhead = { [weak owner] in owner?.playhead ?? 0 }
        skAdNetwork = descriptor.skan.map { SKAdNetworkImpression(skan: $0, adId: descriptor.id) }
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
        // Shown already: the creative was loaded, and its expiry no longer matters.
        if wasShown { return }
        try checkLoadable()
        if isLoaded, loading == nil { return }
        let task = loading ?? startLoading()
        try await awaitShared(task)
    }

    /// `checkUsable` as `load()` reports it: a creative that failed is `creativeFailed(code:)`, whenever it
    /// failed, never `invalidated(.creativeFailed)` (an `ad.error` right after `ad.loaded` included).
    private func checkLoadable() throws {
        do {
            try checkUsable()
        } catch VideoAdError.invalidated(.creativeFailed(let code)) {
            throw VideoAdError.creativeFailed(code: code)
        }
    }

    /// The app does not use the ad: the SDK sends the `notUsed` beacon (the server tells the DSP), drops the
    /// ad and releases its WebView, if any. Works until `show`, loading or loaded; a `load()` in flight
    /// throws `invalidated(.rejected)`, a later `show` too. Synchronous and fire-and-forget. Not `throws`:
    /// an ad that already ended (expired, rejected, destroyed, failed) needs no notice and one that was
    /// shown cannot be rejected, so both are no-ops, with a console line; nothing is left to handle.
    public func reject(_ reason: RejectReason = .notUsed) {
        withContentPlayhead {
            if wasShown {
                Logger.warning("\(format) ad \(id.prefix(8)): reject() after show does nothing; the ad was shown")
                return
            }
            if let invalidationReason {
                Logger.info("\(format) ad \(id.prefix(8)): reject() does nothing, the ad already ended (\(invalidationReason))")
                return
            }
            if descriptor.isExpired {
                // No notice: the server closes an expired ad itself.
                invalidate(.expired)
                Logger.info("\(format) ad \(id.prefix(8)): reject() does nothing, the ad expired")
                return
            }
            Logger.info("\(format) ad \(id.prefix(8)): rejected (\(reason))")
            // Committed before the beacon: the rejection is final the moment the app asked for it.
            invalidate(.rejected)
            tracker.fire("notUsed", notUsed: Tracker.NotUsed(reason))
        }
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
                try checkLoadable()
                throw error
            }
            // Expired while the page loaded, or failed right after it: the result is dropped.
            try checkLoadable()
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
    /// Throws when the show cannot begin, with nothing fired: `wrongPresentation` (a linear ad),
    /// `alreadyShown`, `anotherAdShowing`, `invalidated` (`.contentChanged` too: show an episode's ads only in
    /// that episode, see `VideoAds.track(_:)`), `destroyed`, `disabled`, `presenterUnavailable`
    /// (the view is not in a window, has no area, or it, an ancestor or its window is hidden or transparent;
    /// or the app is not active or the view's window scene is not in the foreground and active: the content
    /// in Picture in Picture only, the lock screen, background audio, Control Center over the app),
    /// `containerTooSmall`, and `contentPaused` (an overlay over paused content); the ad stays ready in these
    /// three. Otherwise `show` was accepted: the ad is on screen, or, if code of yours that UIKit or the player
    /// ran during the call ended it, `didEnd` already arrived (`hasEnded == true`); from `show` until `didEnd`
    /// the SDK retains it. The ad follows the
    /// view when it resizes or rotates: the same variant is fitted again, and a view too small for it ends it
    /// with `.interrupted`. With a player tracked by `VideoAds.track(_:)`, an overlay also ends when the content
    /// stops, and a pause ad when the content plays again, both as `.interrupted`; an overlay whose content
    /// paused in the background stays until a second after the app's return, and goes on if it plays again.
    ///
    /// `insets` keep an overlay or a pause card clear of your own controls: they add to the view's safe area,
    /// as UIKit's `additionalSafeAreaInsets` do, so `bottom: 80` places a bottom strip 80 points above the
    /// safe area's edge. Kept while the ad is shown, through resizes and rotations, and counted in
    /// `containerTooSmall`'s minimum. A full-screen pause ad ignores them: it fills the view. A negative or
    /// non-finite value counts as zero.
    public func show(in view: UIView, insets: UIEdgeInsets = .zero) throws {
        try withContentPlayhead { try showInline(in: view, insets: insets) }
    }

    private func showInline(in view: UIView, insets: UIEdgeInsets) throws {
        // The public call fits the format: a fact of the linear format, not of its screen.
        guard format != .linear else { throw wrongPresentation("show(in:)", use: "show(from:)") }
        try checkShowable()
        guard ViewabilityMeter.canBeSeen(view) else {
            Logger.warning("ad \(id.prefix(8)): cannot show, the view is not on screen or is hidden")
            throw VideoAdError.presenterUnavailable
        }
        guard ViewabilityMeter.isInFront(view) else {
            Logger.warning("ad \(id.prefix(8)): cannot show, the app or the view's scene is not in front; the ad stays ready")
            throw VideoAdError.presenterUnavailable
        }
        let container = view
        let area = CGRect(origin: .zero, size: container.bounds.size)
        extraInsets = AdGeometry.cleaned(insets)
        let adFrame = descriptor.position == .fullscreen
            ? fullscreenFrame(in: area, safeArea: container.safeAreaInsets)
            : try frame(in: area, safeArea: AdGeometry.adding(extraInsets, to: container.safeAreaInsets))
        // Nothing throws from here on. Reserved before UIKit runs any of the app's code: taking the WebView out
        // of its parking window calls that window's overridable hooks, and adding the host calls the
        // container's. A show from there finds the slot taken; a destroy from there ends this ad, and each
        // step below checks for that. One bridge throughout: after an end, `bridge` would make a new one.
        let bridge = self.bridge
        let screen = InlineScreen(ad: self)
        reserve(on: screen)
        let webView = bridge.takeWebView()
        guard !hasEnded else { return }
        bridge.chosenSize = chosenSize.map { ($0.width, $0.height) }
        let host = screen.attach(webView, to: container, adFrame: adFrame, coversWhole: descriptor.position == .fullscreen)
        // Off screen (the hook's doing, or a feed showing the player's middle, not its top card): ended, no impression.
        if !hasEnded, !ViewabilityMeter.canBeSeen(host) || ViewabilityMeter.visibleShare(of: webView) == 0 {
            Logger.warning("ad \(id.prefix(8)): nothing of the ad is on screen where it was placed; ended as interrupted")
            end(.interrupted)
            return
        }
        contentRule.endIfContentStopped()
        reachedScreen()
    }

    /// Presents a linear ad full screen. From `viewController` when given, which must be on screen
    /// and not already presenting; with `nil` (the default) from the key window's top view controller,
    /// the usual default for a full-screen ad. Pass the controller when the guess would
    /// be wrong: a player presented as a sheet, a second window, a hosting controller that is not yours.
    /// Throws when the show cannot begin, with nothing fired: `wrongPresentation` (an overlay or pause
    /// ad), `alreadyShown`, `anotherAdShowing`, `invalidated`, `destroyed`, `disabled`,
    /// `presenterUnavailable` (the controller cannot present, or the app or its window scene is not in the
    /// foreground and active; the ad stays ready: try again once the app is back, or pass the right
    /// controller). Otherwise `show` was accepted: the ad is being presented, or, if code of yours that UIKit
    /// ran during the call ended it, `didEnd` already arrived (`hasEnded == true`). Only the SDK dismisses it:
    /// the video completing, a skip, a close, an error, or an
    /// interruption, each ending in one `didEnd`. From here until `didEnd` the SDK retains the ad.
    public func show(from viewController: UIViewController? = nil) throws {
        try withContentPlayhead { try showLinear(from: viewController) }
    }

    private func showLinear(from viewController: UIViewController?) throws {
        // The public call fits the format: a fact of the linear format, not of its screen.
        guard format == .linear else { throw wrongPresentation("show(from:)", use: "show(in:)") }
        try checkShowable()
        let presenter: UIViewController
        if let viewController {
            guard ViewabilityMeter.canBeSeen(viewController.view), viewController.presentedViewController == nil,
                  !viewController.isBeingPresented, !viewController.isBeingDismissed else {
                Logger.warning("ad \(id.prefix(8)): cannot present, the view controller is not on screen or already presenting")
                throw VideoAdError.presenterUnavailable
            }
            presenter = viewController
        } else {
            guard let top = LinearViewController.topPresenter(), ViewabilityMeter.canBeSeen(top.view) else {
                Logger.warning("ad \(id.prefix(8)): cannot present, no view controller on the key window can present now")
                throw VideoAdError.presenterUnavailable
            }
            presenter = top
        }
        guard ViewabilityMeter.isInFront(presenter.view) else {
            Logger.warning("ad \(id.prefix(8)): cannot present, the app or the presenter's scene is not in front; the ad stays ready")
            throw VideoAdError.presenterUnavailable
        }
        // Reserved first, so a completion that runs at once finds the ad shown and the slot taken, and before
        // the WebView leaves its parking window, whose overridable hooks are the app's code (a show from
        // there finds the slot taken; a destroy ends this ad, checked below). The page is shown, and the
        // beacons of that moment fire, once UIKit confirms the presentation: an ad UIKit refused must never
        // record an impression.
        let screen = LinearScreen(ad: self)
        reserve(on: screen)
        let webView = bridge.takeWebView()
        guard !hasEnded else { return }
        let controller = screen.attach(webView)
        // The meter starts once the presentation is on screen; a tick during the transition would read
        // exposure 0 and make the page pause the video it has just started.
        Logger.debug("ad \(id.prefix(8)): reserved, waiting for UIKit to present it")
        LinearPresentation.present(controller, from: presenter, adId: id, timeout: Self.showTimeout) { [weak self] in
            self?.state.phase == .reserved
        } onPresented: { [weak self, weak controller] in
            guard case .ending? = self?.state.phase else { return self?.reachedScreen() ?? () } // ended mid-animation: UIKit dropped that dismiss
            if controller?.isBeingDismissed == false { controller?.presentingViewController?.dismiss(animated: true) }
        } onFailed: { [weak self] in
            guard let self else { return }
            ErrorReporter.shared.report(.presentationFailed, stage: .presentation, sessionId: owner?.sessionId, adId: id,
                                        recovery: .adEndedFailed)
            fail(.presenterUnavailable)
        }
    }

    /// The ends a video before its first frame reports as `close`: none fired a beacon of its own.
    private static let closedBeforeFirstFrame: [EndReason] = [.dismissed, .destroyed, .interrupted, .completed]

    /// How long a linear ad may take to reach the screen before the ad gives up on it.
    static var showTimeout: TimeInterval = 2
    /// How long a linear dismissal may take before `didEnd` comes anyway, once the controller left the screen (five
    /// times that if not): a completion UIKit never calls must not keep the app waiting, nor one still running be cut.
    static var dismissalTimeout: TimeInterval = 1

    /// Ends an overlay or pause ad because the app says so: the page is removed, `overlayViewDuration`
    /// fires, and the delegate gets `didEnd(.dismissed)`. Terminal; the ad cannot be shown again. For an
    /// overlay with a `duration` this is the way to end it earlier (the content ended, a seek); left alone,
    /// the SDK removes it when the duration elapses, with `didEnd(.completed)`. An overlay without one,
    /// like a pause ad, stays until this, the viewer's close control or `destroy()`. Before `show` and
    /// after `didEnd` it does nothing. A linear ad ignores it: it ends by itself or by the viewer's Skip or
    /// close, and `destroy()` is the way to force it off. Calling it on one is a programmer error, which
    /// stops a debug build and is logged in a release build. Not `throws`: nothing here can fail at run
    /// time, and a `try` would only hide that mistake behind a `try?`.
    public func dismiss() {
        // A fact of the linear format, not of its screen: the public API leaves its end to the ad and the viewer.
        guard format != .linear else {
            Environment.assertionFailure("VideoAd.dismiss() on a linear ad; it ends by itself, destroy() forces it off")
            Logger.error("ad \(id.prefix(8)): dismiss() on a linear ad does nothing; it ends by itself or by the viewer, destroy() forces it off")
            return
        }
        guard wasShown, !hasEnded else { return }
        Logger.debug("ad \(id.prefix(8)): dismissed by the app")
        end(.dismissed)
    }

    private func checkShowable() throws {
        let contentPaused = runAppCodeBeforeShow()
        if wasShown { throw VideoAdError.alreadyShown }
        try checkUsable()
        // An episode's ads only in that episode: one requested for it is counted for it.
        if contentRule.checksEpisode, owner?.playback.playsAnotherEpisode == true {
            Logger.warning("ad \(id.prefix(8)): cannot show, its episode no longer plays in the tracked player; ended as contentChanged")
            invalidate(.contentChanged)
            throw VideoAdError.invalidated(.contentChanged)
        }
        if KontextVideo.shared.adOnScreen != nil { throw VideoAdError.anotherAdShowing }
        guard isLoaded else { throw VideoAdError.notLoaded }
        if contentPaused { throw VideoAdError.contentPaused }
    }

    /// `show` committed: the ad takes the app's one slot, the SDK retains it, it leaves its `VideoAds`'s
    /// unshown ones; `show` returning is the app's signal. Before any of the app's code can run, so a show
    /// from inside it finds the slot taken. The creative itself goes on screen in `reachedScreen()`: at once for
    /// an overlay or pause ad, once UIKit confirmed it for a linear ad.
    private func reserve(on screen: any AdScreen) {
        state.moveTo(.reserved)
        shownAd = ShownAd.begin(self, owner: owner, screen: screen)
    }

    /// The creative is on screen: the page is told, the meter and the clocks run, the beacons of the moment
    /// fire. Everything the ad needs while on screen is set up before anyone outside hears of it: the
    /// impression delegate at the end may end the ad on the spot, and `end()` must find all of it.
    func reachedScreen() {
        withContentPlayhead {
            guard state.moveTo(.onScreen) else { return }
            bridge.show()
            Logger.info("ad \(id.prefix(8)): shown")
            DebugReporter.shared.event("ad.shown", adId: id, state: ["format": .string(format.rawValue)])
            startMeter()
            // Apple counts display, not the VAST impression: an app-install ad is registered as it appears.
            skAdNetwork?.start()
            // An inline ad's clock starts, and its content rule with it.
            shownAd?.screen.reachedScreen()
            // At `ad.show`: creativeView and the AdChoices icon's view; the impression too for an image or
            // HTML creative, while a video's waits for its first frame. A video's impression waits for
            // `video.start`. The page owns the start timeout (3 s, then `ad.error` 405) and, when autoplay
            // was refused, waits for the viewer's tap as long as it takes; the SDK keeps no start timer, it
            // could not tell the two apart.
            // Following the content read the app's player above, which may have ended the ad. The beacons
            // themselves call no app code: they use the playhead read before this operation.
            guard !hasEnded else { return }
            tracker.fire("creativeView")
            tracker.fire("iconView")
            if descriptor.creative != .video {
                recordImpression()
            }
        }
    }

    // MARK: Measurement

    func recordImpression() {
        guard !hasEnded, state.markImpression() else { return }
        tracker.fire("impression")
        Logger.info("ad \(id.prefix(8)): impression")
        guard !hasEnded else { return }
        delegate?.videoAdDidRecordImpression(self)
    }

    /// Viewability: 50 % of the box on screen for 1 s (image) or 2 s (video) is `viewable`; the page
    /// hears every exposure change (`ad.exposure`) and pauses a video at 0.
    private func startMeter() {
        guard !hasEnded, meter == nil else { return }
        let meter = ViewabilityMeter(view: bridge.webView, requiredSeconds: descriptor.creative == .video ? 2 : 1)
        // MRC: two seconds of the video *played*. Exposure is measured from show, for the page; the
        // viewability clock runs only while the video plays (from `video.start`, not while paused).
        meter.countsTime = descriptor.creative != .video || isVideoPlaying
        meter.onExposure = { [weak self] percentage, visible in
            self?.bridge.exposure(percentage: percentage, visibleRectangle: visible)
        }
        // At most one verdict per ad, after its impression: an ad never counted has nothing to be viewable.
        meter.onVerdict = { [weak self] verdict in
            guard self?.state.hasImpression == true else { return }
            self?.withContentPlayhead { self?.tracker.fire(verdict.rawValue) }
            Logger.info("ad \(self?.id.prefix(8) ?? ""): \(verdict.rawValue)")
        }
        // The app took the view away (navigated off without dismiss()): the ad ends, or it would block every
        // show in the app. Not a linear ad covered full screen (the screen's `isCovered`): UIKit removes its view
        // until the cover goes.
        meter.onDetached = { [weak self] in
            guard let self, !hasEnded else { return }
            if self.meter?.isCovered?() == true { return }   // asked again each tick
            Logger.warning("ad \(id.prefix(8)): its view left the window; ended as interrupted")
            end(.interrupted)
        }
        // What the screen adds: the clock and the off-screen rule inline, the covered check full screen.
        shownAd?.screen.configure(meter: meter)
        shownAd?.meter = meter
        meter.start()
    }

    // MARK: Ending

    /// The creative broke on screen, or never got there: `didFail` then `didEnd(.failed)`, in that order and
    /// with that reason, whatever the app does inside `didFail` (a `destroy()` there changes nothing).
    func fail(_ error: VideoAdError) {
        guard wasShown, !hasEnded else { return }
        state.markFailed(error)
        end(.failed)
    }

    /// The one terminal moment after a successful show. Idempotent.
    func end(_ reason: EndReason) {
        withContentPlayhead { endNow(reason) }
    }

    // Every end releases, in this order (an ad ended before show: `invalidate` releases what it ever had, the
    // load waiter, the page and its place in the owner):
    //  1. waiters: none left once shown, the load is over; the presentation watchdog stops on `hasEnded`;
    //  2. timers and clock: the content rule's recheck (endNow), the clock with its timer and scene observers
    //     (`InlineScreen.tearDown`);
    //  3. observers and meter: the viewability meter (the screen's `tearDown`), the SKAdNetwork impression (endNow);
    //  4. renderer: the page (hidden, released; endNow) and the host view (`InlineScreen.tearDown`);
    //  5. presentation: the linear controller dismissed (`LinearScreen.close`); there is no registration to undo on iOS;
    //  6. context: none on iOS;
    //  7. the app-wide on-screen slot, `KontextVideo.shownAd` (`ShownAd.release`, from finish);
    //  8. player binding: the owner's showing ad and its ticks, `VideoAds.adDidEnd` (`ShownAd.release`);
    //  9. delegate: held weakly, nothing to drop; `didEnd` is the last call (finish).
    private func endNow(_ reason: EndReason) {
        guard state.moveTo(.ending(reason)) else { return }
        if reason == .failed, let failure = state.failure {
            delegate?.videoAd(self, didFail: failure)
        }
        contentRule.cancel()
        // The ad was on screen, whatever ended it; `[KONTEXT_VIEWDURATION]` is the active time, not the wall clock.
        let activeTime = shownAd?.tearDown() ?? 0
        skAdNetwork?.end()
        loadedBridge?.hide()
        loadedBridge = nil   // an ended ad keeps its facts, not a WebView
        // A linear ad's controller is dismissed, and `didEnd` waits for it; an inline ad is gone already.
        let dismissing = shownAd?.screen.close { [weak self] hasTimedOut in
            guard let self else { return }
            if hasTimedOut {
                // Reported over a controller UIKit did not take down: the app is not kept waiting, and the log says so.
                Logger.error("ad \(id.prefix(8)): the linear ad's dismissal did not finish in \(Int(Self.dismissalTimeout * 5)) s; didEnd delivered anyway")
                DebugReporter.shared.event("ad.dismissalTimedOut", adId: id, level: .warning)
                ErrorReporter.shared.report(.dismissalTimedOut, stage: .presentation, sessionId: owner?.sessionId, adId: id,
                                            recovery: .didEndDelivered)
            }
            finish(reason)
        } ?? false
        // A video on screen that never reached its first frame (`video.start`), ended by the app, an interruption,
        // a destroy or its own time: `close` is the outcome the server counts as shown, not billed. A failure
        // already fired `error`; the page's own close or skip fired its beacon; an image's impression fires at
        // show; an ad that never reached the screen fired nothing to close. As the Kotlin SDK decides it.
        if state.wasOnScreen, descriptor.creative == .video, !state.hasImpression, Self.closedBeforeFirstFrame.contains(reason) {
            tracker.fire("close")
        }
        if shownAd?.screen.isInline == true {
            tracker.fire("overlayViewDuration", viewDurationMs: Int((activeTime * 1000).rounded()))
        }
        Logger.info("ad \(id.prefix(8)): ended (\(reason))")
        DebugReporter.shared.event("ad.ended", adId: id, state: ["reason": .string("\(reason)")])
        if !dismissing { finish(reason) }
    }

    /// The screen is free and the app hears `didEnd`: at once for an overlay or pause ad, once the
    /// dismissal finished for a linear ad. Once.
    private func finish(_ reason: EndReason) {
        guard state.moveTo(.ended(reason)) else { return }
        shownAd?.release()
        shownAd = nil
        delegate?.videoAd(self, didEnd: reason)
    }

    // MARK: The page's events

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

    // MARK: Ending before show

    /// The ad ends before `show`: it leaves its `VideoAds` (never served again), its WebView is released,
    /// a `load()` in flight throws. For an ad on screen nothing happens; `destroy()` ends that one with
    /// `didEnd(.destroyed)`. No beacon here: `reject` and `destroy` fire `notUsed` themselves, an expired
    /// ad is the server's to close (it knows `expires`), a failed creative already fired `error`.
    func invalidate(_ reason: InvalidationReason) {
        guard state.moveTo(.invalidated(reason)) else { return }
        Logger.debug("\(format) ad \(id.prefix(8)) ended before show: \(reason)")
        DebugReporter.shared.event("ad.invalidated", adId: id, state: reason.reportState)
        loadedBridge?.hide()
        loadedBridge = nil
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(throwing: Self.error(for: reason))
        }
        owner?.adDidLeave(self)
    }
}
