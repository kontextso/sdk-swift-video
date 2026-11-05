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
/// What stays here is what needs WebKit or a timer: the WebView's setup, the message handler, the load and its
/// timeout, parking, `evaluateJavaScript`, the navigation and UI delegates, and the teardown.
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
    }

    let adId: String
    let webView: WKWebView
    /// The protocol's rules and state: what each message means, and whether it counts now.
    private(set) var frameProtocol: FrameProtocol
    var state: PageState { frameProtocol.state }
    /// Set as the bridge fails, before the `.error` event goes out.
    private(set) var failureCause: FailureCause?
    /// The system error behind a page that could not load, as a domain and a code.
    private(set) var failureUnderlying: ErrorReport.Underlying?
    var onEvent: ((FrameEvent) -> Void)?

    private var loadTimeoutTask: Task<Void, Never>?
    private let messageHandler = MessageHandler()
    private let touchRecognizer = TouchRecognizer()

    /// `videoDuration`: the video's length when the server gives one (a linear ad); without it the playhead is
    /// capped at a day.
    init(adId: String, url: URL, isVideo: Bool, videoDuration: TimeInterval? = nil) {
        self.adId = adId
        frameProtocol = FrameProtocol(adId: adId, pageURL: url, isVideo: isVideo, videoDuration: videoDuration)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The ad plays where the SDK put it: never in a PiP window or on an AirPlay screen out of our measurement.
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.dataDetectorTypes = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(messageHandler, name: "kontext")
        if !Environment.asksBeforeMediaCapture() {
            configuration.userContentController.addUserScript(Self.noMediaCapture)
        }
        for (scheme, handler) in Environment.schemeHandlers {
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        messageHandler.bridge = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        touchRecognizer.onTouch = { [weak self] in self?.noteTouch() }
        webView.addGestureRecognizer(touchRecognizer)
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
    }

    /// A creative never reaches the camera or microphone. From iOS 15 WebKit asks the UI delegate, which
    /// denies; on iOS 14 it would ask the viewer directly, so the capture API is taken out of every frame
    /// before the page's own scripts run: the standard one and the legacy prefixed ones.
    static let noMediaCapture = WKUserScript(source: """
        (function () {
          try { delete MediaDevices.prototype.getUserMedia; } catch (e) {}
          try { delete Navigator.prototype.getUserMedia; delete Navigator.prototype.webkitGetUserMedia; } catch (e) {}
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

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
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "kontext")
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

    /// Loads the page. `ad.loaded` must arrive within `loadTimeout` of active time: WebKit does not run a
    /// page in the background, so time there does not count. A load started in the background finds no window
    /// to park in; the same active-time check parks it on the first tick the app is active again, or a video
    /// creative would never buffer and the timeout would fail a working ad.
    func load() {
        Logger.debug("frame \(adId.prefix(8)): loading \(frameProtocol.pageURL)")
        parkOffscreen()
        webView.load(URLRequest(url: frameProtocol.pageURL))
        loadTimeoutTask = Task { [weak self] in
            let step = min(0.25, Self.loadTimeout)
            // Active time as it passed, not the step asked for: a tick that fires late counts what it waited.
            var waited: TimeInterval = 0
            var last = ProcessInfo.processInfo.systemUptime
            while waited < Self.loadTimeout {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if Environment.isApplicationActive() {
                    waited += now - last
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
    /// WebView sits in the key window, invisible and inert, at the size the ad will have. Removed on show
    /// (the ad's own view takes it) and on end.
    private func parkOffscreen() {
        guard webView.window == nil, let window = Environment.parkingWindow() else { return }
        webView.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: window.bounds.height)
        webView.alpha = 0
        webView.isUserInteractionEnabled = false
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

    /// The envelope as the page receives it: `{ adId, type, ...payload }`.
    static func envelope(adId: String, type: String, payload: [String: Any]) -> String? {
        var message: [String: Any] = ["adId": adId, "type": type]
        payload.forEach { message[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return nil }
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

    fileprivate func receive(_ message: WKScriptMessage) {
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

    /// The viewer touched the WebView; a URL may be opened for `FrameProtocol.touchWindow` seconds.
    func noteTouch() {
        frameProtocol.noteTouch(now: Environment.now())
    }

    /// Terminal with an error; after the end nothing is reported any more.
    private func fail(_ event: FrameEvent, cause: FailureCause) {
        guard state != .ended else { return }
        failureCause = cause
        end()
        onEvent?(event)
    }

    /// Terminal: the page is stopped and nothing is accepted or sent any more.
    private func end() {
        guard frameProtocol.end() else { return }
        loadTimeoutTask?.cancel()
        unpark()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kontext")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// A navigation out of our origin is a click the page could not report: honoured only after a touch;
    /// without one it is a forced redirect and goes nowhere.
    func externalNavigation(to target: URL) {
        guard let click = frameProtocol.externalNavigation(to: target, now: Environment.now()) else {
            Logger.warning("frame \(adId.prefix(8)): navigation to \(target.absoluteString) cancelled")
            return
        }
        onEvent?(click)
    }
}

// MARK: - WKNavigationDelegate

extension FrameBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let type = navigationAction.navigationType
        let isSubmission = type == .formSubmitted || type == .formResubmitted
            || (navigationAction.request.httpMethod ?? "GET").uppercased() != "GET"
        switch frameProtocol.navigationDecision(to: target, isMainFrame: navigationAction.targetFrame?.isMainFrame != false,
                                                  isReload: type == .reload, isSubmission: isSubmission, current: webView.url) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            Logger.warning("frame \(adId.prefix(8)): the page tried to replace itself after it was ready; refused")
            decisionHandler(.cancel)
        case .external:
            decisionHandler(.cancel)
            externalNavigation(to: target)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(responseDecision(navigationResponse.response, isMainFrame: navigationResponse.isForMainFrame,
                                         canShowMIMEType: navigationResponse.canShowMIMEType))
    }

    /// What a response may do, over plain values so the tests can pass a status (a custom scheme reaches
    /// WebKit's policy without one). The page itself answered with an error status (a 410 after `expires`, a
    /// 404, a 5xx): the load fails now, as a page that could not load, not after the load timeout over an
    /// error page. No downloads: only what the WebView can render itself.
    func responseDecision(_ response: URLResponse, isMainFrame: Bool, canShowMIMEType: Bool) -> WKNavigationResponsePolicy {
        if isMainFrame, state == .loading, let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            Logger.warning("frame \(adId.prefix(8)): page answered \(status)")
            failureUnderlying = ErrorReport.Underlying(httpStatus: status)
            fail(.error(code: frameProtocol.loadErrorCode), cause: .loadFailed)
            return .cancel
        }
        return canShowMIMEType ? .allow : .cancel
    }

    /// A new document starting in the main frame after the page was ready: one the policy above let through
    /// would replace the creative and its close control under an ad still shown. The backstop ends the ad; a
    /// navigation within the document (a fragment) never starts one.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageReplaced()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageReplaced()
    }

    private func pageReplaced() {
        guard state == .loaded || state == .shown else { return }
        Logger.warning("frame \(adId.prefix(8)): the page replaced itself after it was ready; the ad ends")
        webView.stopLoading()
        fail(.error(code: frameProtocol.failureCode), cause: .page)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// The page answered but failed while loading its content (a dropped connection mid-document).
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// A navigation that failed before the page said `ad.loaded` fails the ad. A navigation we or WebKit
    /// stopped on purpose (a refused or external link, one replaced by the next) is not a failure.
    private func loadFailed(_ error: Error) {
        guard state == .loading, !Self.isInterruption(error) else { return }
        Logger.warning("frame \(adId.prefix(8)): page failed to load, \(error.localizedDescription)")
        failureUnderlying = ErrorReport.Underlying(error)
        fail(.error(code: frameProtocol.loadErrorCode), cause: .loadFailed)
    }

    /// `NSURLErrorCancelled`, and WebKit's "frame load interrupted by policy change" (102) after a `.cancel` decision.
    static func isInterruption(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.warning("frame \(adId.prefix(8)): web content process terminated")
        // 405 is a failure while playing; an ad loaded but never shown gets the load error, like any other.
        fail(.error(code: frameProtocol.failureCode), cause: .processTerminated)
    }
}

// MARK: - WKUIDelegate

extension FrameBridge: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A `target="_blank"` link: no new window, treated like any other navigation out.
        if let target = navigationAction.request.url {
            externalNavigation(to: target)
        }
        return nil
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // The page's dialogs are answered at once, as dismissed. All three in their `async` form: the
    // completion-handler forms' closure types differ between the iOS 18 and iOS 26 SDKs, and a signature
    // that misses is never called (the CI warnings gate catches it on Xcode 16.4).
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        nil
    }
}

// MARK: - Helpers

/// Receives the page's messages without the retain cycle `WKUserContentController` creates with its handlers.
private final class MessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: FrameBridge?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            bridge?.receive(message)
        }
    }
}

/// Notes when the viewer touches the WebView, without taking the touch away from the page.
private final class TouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

extension FrameProtocol.Sender {
    /// In an extension, so the memberwise initializer the tests use stays synthesized.
    @MainActor
    init(_ frame: WKFrameInfo) {
        self.init(isMainFrame: frame.isMainFrame, scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
    }
}
