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

    /// What the viewer earns when a rewarded interstitial completes.
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
        /// The `KontextVideoPlayer` object was deallocated. Terminal for the `VideoAds`: create a new one
        /// with the new player.
        case playerUnavailable
    }

    public let id: String
    public let placementId: String
    public let format: AdFormat
    public let price: Price
    /// When the ad stops being showable. The server sends a relative lifetime; this is it as a `Date`, for
    /// the app's eyes. The SDK's own check runs on the monotonic clock, so a changed device clock cannot
    /// expire an ad early or late.
    public let expirationDate: Date
    /// `nil` for an interstitial.
    public let position: Position?
    /// `nil` for an interstitial and for a full-screen pause ad.
    public let size: Size?
    /// Overlay: how long it stays on screen. Interstitial: the video's length. Seconds; `nil` for a pause ad.
    public let duration: TimeInterval?
    /// Interstitial: seconds until the Close may appear; `nil` means no Close before the video completes.
    public let skipOffset: TimeInterval?
    /// Set on a rewarded interstitial.
    public let reward: Reward?
    public let trigger: Trigger

    /// Whether `show` can be called: the creative is loaded, the ad was not shown yet and not invalidated.
    /// A hint for "show or load" decisions, not the authority: the box is measured only at `show`, and
    /// `show` throws when it cannot begin.
    public var isReady: Bool {
        isLoaded && !wasShown && invalidationReason == nil && !isExpired
    }

    /// Why the ad was invalidated, once it was.
    public private(set) var invalidationReason: InvalidationReason?

    /// Receives the ad's moments. Held weakly.
    public weak var delegate: (any VideoAdDelegate)?

    /// `true` from a successful `show` on; an ad is shown at most once.
    public private(set) var wasShown = false
    /// `true` once `didEnd` was delivered.
    public private(set) var hasEnded = false

    /// Below this share of the nominal size the ad is not shown.
    static let minimumScale: CGFloat = 0.5

    /// The wire object, for the steps that render and track it.
    let ad: AdPayload
    /// `ProcessInfo.systemUptime` at receipt: `expires` counts from here.
    let receivedAt: TimeInterval
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
    /// `video.complete` arrived; the next `ad.close` is the end card closing, not the viewer giving up.
    private var completed = false
    /// Delivers `didInvalidate(.expired)` when the time comes.
    private var expiryTask: Task<Void, Never>?

    init(ad: AdPayload) {
        let now = ProcessInfo.processInfo.systemUptime
        let lifetime = TimeInterval(ad.expires) / 1000
        self.ad = ad
        self.receivedAt = now
        id = ad.id
        placementId = ad.placementId
        format = ad.format
        price = Price(value: ad.price.value, currency: ad.price.currency, precision: ad.price.precision == .exact ? .exact : .estimated)
        expirationDate = Date().addingTimeInterval(lifetime)
        switch ad.trigger {
        case .manual: trigger = .manual
        case .window(let from, let to): trigger = .window(from: TimeInterval(from) / 1000, to: TimeInterval(to) / 1000)
        }
        switch ad.details {
        case .overlay(let position, let size, let duration):
            self.position = position == .top ? .top : .bottom
            self.size = Size(width: size.width, height: size.height)
            self.duration = TimeInterval(duration) / 1000
            skipOffset = nil
            reward = nil
        case .pause(let position, let size):
            switch position {
            case .top: self.position = .top
            case .bottom: self.position = .bottom
            case .fullscreen: self.position = .fullscreen
            }
            self.size = size.map { Size(width: $0.width, height: $0.height) }
            duration = nil
            skipOffset = nil
            reward = nil
        case .interstitial(let duration, let skipOffset, let reward):
            position = nil
            size = nil
            self.duration = TimeInterval(duration) / 1000
            self.skipOffset = skipOffset.map { TimeInterval($0) / 1000 }
            self.reward = reward.map { Reward(label: $0.label, amount: $0.amount) }
        }
        switch ad.rendering {
        case .frame(let url):
            bridge = FrameBridge(adId: ad.id, url: url, isVideo: ad.creative == .video)
        }
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        bridge.load()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard let self, !Task.isCancelled, !wasShown else { return }
            invalidate(.expired)
        }
    }

    // MARK: Showing

    /// Shows an overlay or pause ad inside the player's view, at the ad's `position` and `size` (a full-
    /// screen pause ad fills the view). Throws when presentation cannot begin, with nothing fired:
    /// `alreadyShown`, `invalidated`, `containerTooSmall` (the ad is discarded), `playerUnavailable`.
    /// From here until `didEnd` the SDK retains the ad.
    public func show() throws {
        guard format != .interstitial else {
            assertionFailure("KontextVideo: an interstitial is shown with show(from:)")
            throw VideoAdError.cannotPresent
        }
        try checkShowable()
        guard let player = owner?.player else {
            owner?.playerIsGone()
            throw VideoAdError.invalidated(.playerUnavailable)
        }
        let container = player.view
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

    /// Ends an overlay or pause ad because the app says so: the page is removed, `overlayViewDuration`
    /// fires, and the delegate gets `didEnd(.dismissed)`. Terminal; the ad cannot be shown again.
    public func dismiss() {
        guard wasShown, !hasEnded else { return }
        Logger.debug("ad \(id.prefix(8)): dismissed by the app")
        end(.dismissed)
    }

    private func checkShowable() throws {
        if wasShown { throw VideoAdError.alreadyShown }
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

    /// Presentation began: the page is told, the owner retains the ad, the delegate hears `didShow`.
    private func begin() {
        wasShown = true
        expiryTask?.cancel()
        owner?.adDidBeginShowing(self)
        bridge.show()
        Logger.info("ad \(id.prefix(8)): shown")
        delegate?.videoAdDidShow(self)
        if ad.creative == .image {
            recordImpression()
        }
    }

    private func recordImpression() {
        // TODO(step 4): fire the `impression` (and `creativeView`) entries.
        Logger.info("ad \(id.prefix(8)): impression")
        delegate?.videoAdDidRecordImpression(self)
    }

    /// The one terminal moment after a successful show. Idempotent.
    func end(_ reason: EndReason) {
        guard wasShown, !hasEnded else { return }
        hasEnded = true
        bridge.hide()
        hostView?.removeFromSuperview()
        hostView = nil
        if format != .interstitial {
            // TODO(step 4): fire `overlayViewDuration`, except for `.destroyed`.
            Logger.debug("ad \(id.prefix(8)): overlayViewDuration")
        }
        Logger.info("ad \(id.prefix(8)): ended (\(reason))")
        owner?.adDidEnd(self)
        delegate?.videoAd(self, didEnd: reason)
    }

    /// Opens a URL the page asked for: the app store, a deep link, a web page. The fallback is tried when
    /// the first cannot be opened (an app that is not installed).
    private func open(_ url: URL, fallback: URL?) {
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened, let fallback {
                UIApplication.shared.open(fallback, options: [:])
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
            loadContinuation?.resume()
            loadContinuation = nil
        case .loadFailed(let code), .error(let code):
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
            open(url, fallback: fallbackUrl)
            delegate?.videoAd(self, didClick: Click(url: url, area: area))
        case .open(let url, let purpose):
            Logger.info("ad \(id.prefix(8)): open (\(purpose)) \(url.host ?? url.absoluteString)")
            open(url, fallback: nil)
        case .close(let reason):
            end(completed ? .completed : (reason == "resume" ? .resumed : .closed))
        case .skip:
            end(.skipped)
        case .video(let name, _):
            Logger.debug("ad \(id.prefix(8)): video.\(name)")
            if name == "start" {
                recordImpression()
            }
        case .progress(let offset, _):
            Logger.debug("ad \(id.prefix(8)): progress \(offset) ms")
        case .complete:
            completed = true
            Logger.info("ad \(id.prefix(8)): complete")
            if let reward {
                delegate?.videoAd(self, didEarn: reward)
            }
        }
    }

    /// On the monotonic clock, as the SDK decides it.
    var isExpired: Bool {
        ProcessInfo.processInfo.systemUptime - receivedAt >= TimeInterval(ad.expires) / 1000
    }

    /// Whether this ad still counts for its placement's one-at-a-time rule: loading, loaded and unshown,
    /// or showing.
    var occupiesPlacement: Bool {
        if wasShown { return !hasEnded }
        return invalidationReason == nil && !isExpired
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
        expiryTask?.cancel()
        bridge.hide()
        Logger.debug("ad \(id.prefix(8)) invalidated: \(reason)")
        if isLoaded || loadContinuation == nil {
            delegate?.videoAd(self, didInvalidate: reason)
        }
    }
}
