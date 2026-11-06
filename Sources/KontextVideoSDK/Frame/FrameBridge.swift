import Foundation
import UIKit
import WebKit

/// Owns the WebView of one ad and carries the Kontext Frame Protocol v2 between it and the ad: the imperative
/// shell around `FrameProtocol`, which holds the protocol's rules.
///
/// The page posts `JSON.stringify(message)` to `webkit.messageHandlers.kontext`, the same string the Android
/// bridge takes; an object is also accepted. The bridge answers with `window.postMessage` into the page. One
/// bridge, one ad: what a message means, and whether it counts, is `FrameProtocol.accept`'s answer; the bridge
/// carries out the `Step` (logs and reports a drop, stops the load timeout, ends the page, delivers the event).
///
/// ```
///   page ──message──► FrameBridge ──accept──► FrameProtocol
///                         │  ◄──── Step ──────────┘
///                         ├─ drop: log, report a violation once
///                         ├─ loaded / deliver / endThenDeliver ──► onEvent (VideoAd.handle)
///                         └─ end: stop the page, unpark, release WebKit's hooks
/// ```
///
/// What stays here is what needs WebKit or a timer: the messages both ways (`evaluateJavaScript` to the page), the
/// load and its timeout, parking, the navigation delegate, the failures and the teardown. What the page may and may
/// not do (the configuration, the refusals, the touch) is `FrameWebView`'s.
@MainActor
final class FrameBridge: NSObject {
    /// `ad.loaded` must arrive within this. A constant in spirit; a variable so the tests can set it.
    static var loadTimeout: TimeInterval = 10
    /// Why the bridge failed: several causes fire the same VAST code, and the error report keeps them apart.
    enum FailureCause: Sendable {
        /// The page reported `ad.error`.
        case page
        /// No `ad.loaded` within `loadTimeout` of active time.
        case loadTimeout
        /// The page itself could not be loaded (network, an error status, a refused response).
        case loadFailed
        /// WebKit's content process for the page ended; the callback does not say why.
        case processTerminated

        /// The fault report's code for a creative that failed this way.
        var reportCode: ErrorReport.Code {
            switch self {
            case .page: .creativeFailed
            case .loadTimeout: .loadTimeout
            case .loadFailed: .frameLoadFailed
            case .processTerminated: .processTerminated
            }
        }
    }

    let adId: String
    let webView: FrameWebView
    /// The protocol's rules and state: what each message means, and whether it counts now.
    private(set) var frameProtocol: FrameProtocol
    var state: FramePhase { frameProtocol.state }
    /// Set as the bridge fails, before the `.error` event goes out.
    private(set) var failureCause: FailureCause?
    /// The system error behind a page that could not load, as a domain and a code.
    private(set) var failureUnderlying: ErrorReport.Underlying?
    var onEvent: ((FrameEvent) -> Void)?

    private var loadTimeoutTask: Task<Void, Never>?

    /// `videoDuration`: the video's length when the server gives one (a linear ad); without it the playhead is
    /// capped at a day.
    init(adId: String, url: URL, isVideo: Bool, videoDuration: TimeInterval? = nil) {
        self.adId = adId
        frameProtocol = FrameProtocol(adId: adId, pageURL: url, isVideo: isVideo, videoDuration: videoDuration)

        webView = FrameWebView(asksBeforeMediaCapture: Environment.asksBeforeMediaCapture(), schemeHandlers: Environment.schemeHandlers)
        super.init()

        webView.onMessage = { [weak self] in self?.receive($0) }
        webView.onTouch = { [weak self] in self?.noteTouch() }
        webView.onNewWindow = { [weak self] in self?.externalNavigation(to: $0) }
        webView.navigationDelegate = self
    }

    /// The owner dropped the bridge: the page is stopped and the WebView leaves the window it was parked
    /// in, or the window would keep it alive, invisible. The handler registered with WebKit is a weak
    /// proxy, so nothing retains the bridge itself and this is actually reached.
    deinit {
        // Every property is read before anything captures `self`: a deinitializer may not touch stored
        // state after that (Swift 6), and the logger's message is a closure.
        let webView = self.webView
        let timeout = loadTimeoutTask
        let id = adId.prefix(8)
        Logger.debug("frame \(id): released")
        let teardown: @MainActor () -> Void = {
            timeout?.cancel()
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: FrameWebView.messageHandlerName)
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            Task { @MainActor in teardown() }
        }
    }

    /// The most active time one tick of the load timeout counts: a late tick on a busy main thread, not a gap the
    /// app spent suspended.
    static let longestTick: TimeInterval = 2

    /// When the app last became active, on `Environment.now`: a suspension between two ticks that both found the
    /// app active counts only from here.
    private var lastActivation = -TimeInterval.infinity

    /// Loads the page. `ad.loaded` must arrive within `loadTimeout` of active time: WebKit does not run a
    /// page in the background, so time there does not count. A load started in the background finds no window
    /// to park in; the same active-time check parks it on the first tick the app is active again, or a video
    /// creative would never buffer and the timeout would fail a working ad.
    func load() {
        Logger.debug("frame \(adId.prefix(8)): loading \(frameProtocol.pageURL)")
        parkOffscreen()
        webView.load(URLRequest(url: frameProtocol.pageURL))
        // The app's return from a suspension, for the ticks below.
        let activation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastActivation = Environment.now() }
        }
        loadTimeoutTask = Task { [weak self] in
            defer { NotificationCenter.default.removeObserver(activation) }
            let step = min(0.25, Self.loadTimeout)
            // Active time as it passed, not the step asked for: a tick that fires late counts what it waited, up to
            // `longestTick`. A suspension between two ticks that both found the app active is not counted: the
            // tick after it counts from the app's return (`lastActivation`), so that time does not fail a healthy
            // load.
            var waited: TimeInterval = 0
            var last = Environment.now()
            while waited < Self.loadTimeout {
                try? await Task.sleep(seconds: step)
                guard !Task.isCancelled else { return }
                let now = Environment.now()
                if Environment.isApplicationActive() {
                    let from = max(last, self?.lastActivation ?? last)
                    waited += min(max(now - from, 0), Self.longestTick)
                    if let self, state == .loading, !isParked { parkOffscreen() }
                }
                last = now
            }
            guard let self, state == .loading else { return }
            Logger.warning("frame \(adId.prefix(8)): no ad.loaded within \(Int(Self.loadTimeout)) s")
            fail(.error(code: frameProtocol.loadErrorCode), cause: .loadTimeout)
        }
    }

    /// WebKit loads a video's data only for a WebView that is in a window, so while the page loads the
    /// WebView sits in the key window, invisible and inert, at the window's size, and hidden from VoiceOver.
    /// Removed on show (the ad's own view takes it) and on end.
    private func parkOffscreen() {
        guard webView.window == nil, let window = Environment.parkingWindow() else { return }
        webView.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: window.bounds.height)
        webView.alpha = 0
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true   // invisible to the eye, and to VoiceOver too
        window.insertSubview(webView, at: 0)
        isParked = true
    }

    private var isParked = false

    private func unpark() {
        guard isParked else { return }
        isParked = false
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        webView.accessibilityElementsHidden = false
    }

    /// The WebView, visible and interactive, for the caller to place where the ad goes.
    func takeWebView() -> WKWebView {
        unpark()
        return webView
    }

    // MARK: SDK → page

    /// The page is on screen: it starts whatever the creative does when visible, in `size`, the variant the
    /// SDK chose from the ad's `sizes` for the real box (`nil`: the page fills its view). Given here, not kept:
    /// the choice is the screen's (`InlineScreen.chosenSize`).
    func show(size: VideoAd.Size? = nil) {
        guard frameProtocol.show() else {
            Logger.warning("frame \(adId.prefix(8)): show() in state \(state), ignored")
            return
        }
        if let size {
            send("ad.show", ["size": ["width": size.width, "height": size.height]])
        } else {
            send("ad.show")
        }
    }

    /// How much of the box is on screen, from the viewability meter: `percentage` is a share (0–1), the page
    /// gets 0–100, as in MRAID's `exposureChange`, which it relays.
    func exposure(percentage: Double, visibleRectangle: CGRect) {
        guard state == .shown else { return }
        send("ad.exposure", [
            "exposedPercentage": (percentage * 100).rounded(),
            "visibleRectangle": ["x": visibleRectangle.minX, "y": visibleRectangle.minY, "width": visibleRectangle.width, "height": visibleRectangle.height],
        ])
    }

    /// The SDK is removing the page: terminal.
    func hide() {
        guard state != .ended else { return }
        if state == .shown {
            send("ad.hide")
        }
        end()
    }

    /// Every message sent to the page, for tests.
    var onSend: ((String, [String: Any]) -> Void)?

    /// The envelope as the page receives it: `{ adId, type, ...payload }`; `nil` when it is not valid JSON.
    /// Checked first: `JSONSerialization` raises an Objective-C exception, which no `try` catches, for a NaN or
    /// infinite number (an exposure measured on a view with a degenerate transform), and the app would crash.
    static func envelope(adId: String, type: String, payload: [String: Any]) -> String? {
        var message: [String: Any] = ["adId": adId, "type": type]
        payload.forEach { message[$0.key] = $0.value }
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func send(_ type: String, _ payload: [String: Any] = [:]) {
        onSend?(type, payload)
        guard let json = Self.envelope(adId: adId, type: type, payload: payload) else { return }
        webView.evaluateJavaScript("window.postMessage(\(json), window.location.origin)") { _, error in
            if let error { Logger.debug("frame \(self.adId.prefix(8)): \(type) not delivered, \(error.localizedDescription)") }
        }
    }

    // MARK: Page → SDK

    private func receive(_ message: WKScriptMessage) {
        receive(message.body, from: FrameProtocol.Sender(message.frameInfo))
    }

    /// One message from the page: `FrameProtocol` decides, the bridge carries out its step.
    func receive(_ rawBody: Any, from sender: FrameProtocol.Sender) {
        switch frameProtocol.accept(rawBody, from: sender, now: Environment.now()) {
        case .ignore:
            return
        case .drop(let log, let warning, let violation):
            if warning {
                Logger.warning("frame \(adId.prefix(8)): \(log)")
            } else {
                Logger.debug("frame \(adId.prefix(8)): \(log)")
            }
            if let violation {
                ErrorReporter.shared.report(.protocolViolation, stage: state == .shown ? .playback : .load, adId: adId, detail: violation)
            }
        case .loaded:
            Logger.debug("frame \(adId.prefix(8)): ← ad.loaded")
            loadTimeoutTask?.cancel()
            onEvent?(.loaded)
        case .deliver(let event):
            Logger.debug("frame \(adId.prefix(8)): ← \(event)")
            onEvent?(event)
        case .endThenDeliver(let event):
            Logger.debug("frame \(adId.prefix(8)): ← \(event)")
            // The page's own error; its close and skip end the page as plainly.
            if case .error = event { failureCause = .page }
            end()
            onEvent?(event)
        }
    }

    /// The viewer touched the WebView; a URL may be opened for `TouchGate.window` seconds.
    func noteTouch() {
        frameProtocol.noteTouch(now: Environment.now())
    }

    /// Terminal with an error; after the end nothing is reported any more. `underlying`: the system error behind a
    /// page that could not load. Internal for the navigation delegate (`FrameBridge+WKNavigationDelegate`).
    func fail(_ event: FrameEvent, cause: FailureCause, underlying: ErrorReport.Underlying? = nil) {
        guard state != .ended else { return }
        failureCause = cause
        if let underlying { failureUnderlying = underlying }
        end()
        onEvent?(event)
    }

    /// Terminal: the page is stopped and nothing is accepted or sent any more.
    private func end() {
        guard frameProtocol.end() else { return }
        loadTimeoutTask?.cancel()
        unpark()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: FrameWebView.messageHandlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// A navigation out of our origin is a click the page could not report: honoured only after a touch;
    /// without one it is a forced redirect and goes nowhere. While the page loads it cannot be a click (no touch,
    /// nothing shown): the page redirected to another origin (a CDN handing over to an edge host), which WebKit
    /// then reports only as a cancelled load. It fails the load now, not after the load timeout as a timeout.
    func externalNavigation(to target: URL) {
        if state == .loading {
            Logger.warning("frame \(adId.prefix(8)): the page redirected to another origin while loading; the load fails")
            fail(.error(code: frameProtocol.loadErrorCode), cause: .loadFailed)
            return
        }
        guard let click = frameProtocol.externalNavigation(to: target, now: Environment.now()) else {
            Logger.warning("frame \(adId.prefix(8)): navigation to \(target.absoluteString) cancelled")
            return
        }
        onEvent?(click)
    }
}

extension FrameProtocol.Sender {
    /// In an extension, so the memberwise initializer the tests use stays synthesized.
    @MainActor
    init(_ frame: WKFrameInfo) {
        self.init(isMainFrame: frame.isMainFrame, scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
    }
}
