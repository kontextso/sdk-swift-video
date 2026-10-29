import Foundation
import UIKit
import WebKit

/// Owns the WebView of one ad and speaks the Kontext Frame Protocol v2 with its page.
///
/// The page posts to the `kontext` script message handler; the bridge answers with
/// `window.postMessage` into the page. One bridge, one ad: it accepts messages only from the main frame
/// of the page it loaded, carrying its own ad id, and only in an order that makes sense.
@MainActor
final class FrameBridge: NSObject {
    enum State: Sendable {
        case loading
        case loaded
        case shown
        case ended
    }

    /// `ad.loaded` must arrive within this. A constant in spirit; a variable so the tests can set it.
    static var loadTimeout: TimeInterval = 10
    /// A URL is opened only if the viewer touched the WebView this recently.
    static let touchWindow: TimeInterval = 1
    /// Web, store and app deep links all open; `intent:` can start any Android component, and the rest are
    /// not links to anywhere. iOS refuses the latter itself; the SDK's policy says so.
    static let refusedSchemes: Set<String> = ["intent", "javascript", "data", "file", "blob", "about"]

    let adId: String
    let webView: WKWebView
    private(set) var state: State = .loading
    var onEvent: ((FrameEvent) -> Void)?

    private let url: URL
    /// The VAST error code when the page itself does not answer: 400 for a video, 500 otherwise.
    private let loadErrorCode: Int
    private var loadTimeoutTask: Task<Void, Never>?
    private var lastTouchAt: TimeInterval = -.infinity
    private let messageHandler = MessageHandler()
    private let touchRecognizer = TouchRecognizer()

    init(adId: String, url: URL, isVideo: Bool) {
        self.adId = adId
        self.url = url
        loadErrorCode = isVideo ? 400 : 500

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.dataDetectorTypes = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(messageHandler, name: "kontext")
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
    /// page in the background, so time there does not count.
    func load() {
        Logger.debug("frame \(adId.prefix(8)): loading \(url)")
        parkOffscreen()
        webView.load(URLRequest(url: url))
        loadTimeoutTask = Task { [weak self] in
            let step = min(0.25, Self.loadTimeout)
            var waited: TimeInterval = 0
            while waited < Self.loadTimeout {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if Environment.isApplicationActive() { waited += step }
            }
            guard let self, state == .loading else { return }
            Logger.warning("frame \(adId.prefix(8)): no ad.loaded within \(Int(Self.loadTimeout)) s")
            fail(.error(code: loadErrorCode))
        }
    }

    /// WebKit loads a video's data only for a WebView that is in a window, so while the page loads the
    /// WebView sits in the key window, invisible and inert, at the size the ad will have. Removed on show
    /// (the ad's own view takes it) and on end.
    private func parkOffscreen() {
        guard webView.window == nil, let window = Environment.keyWindow() else { return }
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

    /// The variant the SDK chose from the ad's `sizes` for the real box; the page lays it out.
    var chosenSize: (width: Int, height: Int)?

    /// The page is on screen: it starts whatever the creative does when visible, in the chosen size.
    func show() {
        guard state == .loaded else {
            Logger.warning("frame \(adId.prefix(8)): show() in state \(state), ignored")
            return
        }
        state = .shown
        if let chosenSize {
            send("ad.show", ["size": ["width": chosenSize.width, "height": chosenSize.height]])
        } else {
            send("ad.show")
        }
    }

    /// How much of the box is on screen, from the viewability meter.
    func exposure(percentage: Double, visibleRectangle: CGRect) {
        guard state == .shown else { return }
        send("ad.exposure", [
            "exposedPercentage": percentage,
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

    /// Where a message came from, as WebKit reports it.
    struct Sender: Equatable {
        let isMainFrame: Bool
        let scheme: String
        let host: String
        /// 0 for the scheme's default port.
        let port: Int

        init(isMainFrame: Bool, scheme: String, host: String, port: Int) {
            self.isMainFrame = isMainFrame
            self.scheme = scheme
            self.host = host
            self.port = port
        }

        @MainActor
        init(_ frame: WKFrameInfo) {
            self.init(isMainFrame: frame.isMainFrame, scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        receive(message.body, from: Sender(message.frameInfo))
    }

    /// Checks the envelope, the sender and the order; drops anything else without an error.
    func receive(_ rawBody: Any, from sender: Sender) {
        guard state != .ended else { return }
        guard sender.isMainFrame, isFrameOrigin(sender) else {
            Logger.debug("frame \(adId.prefix(8)): message from another frame dropped")
            return
        }
        guard let body = rawBody as? [String: Any],
              body["adId"] as? String == adId,
              let type = body["type"] as? String else {
            Logger.debug("frame \(adId.prefix(8)): malformed message dropped")
            return
        }
        Logger.debug("frame \(adId.prefix(8)): ← \(type)")
        // Milliseconds into the ad video, clamped to a day: a page value near `Int.max` must not reach arithmetic.
        let playhead = min(max(0, (body["playhead"] as? NSNumber)?.intValue ?? 0), 86_400_000)

        switch type {
        case "ad.loaded":
            guard state == .loading else { return }
            loadTimeoutTask?.cancel()
            state = .loaded
            onEvent?(.loaded)
        case "ad.click", "ad.open":
            guard state == .shown, let raw = body["url"] as? String, let url = Self.url(raw) else { return }
            guard Self.isAllowed(url) else {
                Logger.warning("frame \(adId.prefix(8)): \(type) to \(Logger.describe(url)) dropped, scheme refused")
                return
            }
            guard consumeTouch() else {
                Logger.warning("frame \(adId.prefix(8)): \(type) to \(Logger.describe(url)) dropped, no touch before it")
                return
            }
            if type == "ad.click" {
                // The fallback is opened under the same policy; a refused one is dropped, the click stays.
                let fallback = (body["fallbackUrl"] as? String).flatMap(Self.url).flatMap { Self.isAllowed($0) ? $0 : nil }
                onEvent?(.click(url: url, fallbackUrl: fallback, area: VideoAd.Click.Area(body["area"] as? String)))
            } else {
                onEvent?(.open(url: url, purpose: body["purpose"] as? String ?? "unknown"))
            }
        case "ad.close":
            guard state == .shown else { return }
            end()
            onEvent?(.close(reason: (body["reason"] as? String).flatMap(FrameEvent.CloseReason.init(rawValue:)) ?? .close))
        case "video.skip":
            guard state == .shown else { return }
            end()
            onEvent?(.skip(playhead: playhead))
        case "video.complete":
            guard state == .shown else { return }
            onEvent?(.complete(playhead: playhead))
        case "video.progress":
            guard state == .shown, let offset = (body["offset"] as? NSNumber)?.intValue else { return }
            onEvent?(.progress(offset: offset, playhead: playhead))
        case let type where type.hasPrefix("video."):
            guard state == .shown, let event = FrameEvent.VideoEvent(rawValue: String(type.dropFirst("video.".count))) else { return }
            onEvent?(.video(event, playhead: playhead))
        case "ad.error":
            guard state == .loading || state == .loaded || state == .shown else { return }
            fail(.error(code: (body["code"] as? NSNumber)?.intValue ?? (state == .shown ? 405 : loadErrorCode)))
        default:
            Logger.debug("frame \(adId.prefix(8)): unknown message \(type) dropped")
        }
    }

    /// The viewer touched the WebView; a URL may be opened for `touchWindow` seconds.
    func noteTouch() {
        lastTouchAt = ProcessInfo.processInfo.systemUptime
    }

    /// One tap opens one URL: the touch is spent by the first click, open or navigation it authorized, so a
    /// page that reports a tap and also navigates on it does not open twice.
    private func consumeTouch() -> Bool {
        guard ProcessInfo.processInfo.systemUptime - lastTouchAt <= Self.touchWindow else { return false }
        lastTouchAt = -.infinity
        return true
    }

    /// A URL the page may have opened: anything but the refused schemes.
    static func isAllowed(_ target: URL) -> Bool {
        guard let scheme = target.scheme?.lowercased() else { return false }
        return !refusedSchemes.contains(scheme)
    }

    /// The page's origin and nothing else. WebKit reports port 0 for a scheme's default port, so an
    /// explicit 443 in the URL and the origin's 0 are the same origin.
    func isFrameOrigin(_ sender: Sender) -> Bool {
        guard sender.scheme == url.scheme, sender.host == url.host else { return false }
        let expected = Self.effectivePort(of: url)
        return sender.port == expected || (sender.port == 0 && expected == Self.defaultPort(for: url.scheme))
    }

    /// Whether `target` is in the page's origin, with the default port and an explicit one the same.
    func isSameOrigin(_ target: URL) -> Bool {
        target.scheme == url.scheme && target.host == url.host && Self.effectivePort(of: target) == Self.effectivePort(of: url)
    }

    private static func effectivePort(of url: URL) -> Int {
        url.port ?? defaultPort(for: url.scheme)
    }

    private static func defaultPort(for scheme: String?) -> Int {
        scheme == "https" ? 443 : (scheme == "http" ? 80 : 0)
    }

    /// Terminal with an error; after the end nothing is reported any more.
    private func fail(_ event: FrameEvent) {
        guard state != .ended else { return }
        end()
        onEvent?(event)
    }

    /// Terminal: the page is stopped and nothing is accepted or sent any more.
    private func end() {
        guard state != .ended else { return }
        state = .ended
        loadTimeoutTask?.cancel()
        unpark()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kontext")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// A URL the page sent. A click-through may carry a beacon macro (`[KONTEXT_FIREID]`): its brackets are
    /// percent-encoded first, or `URL(string:)` refuses the string (iOS 16) or re-encodes the whole of it
    /// (iOS 17); the tracker reads the encoded form.
    static func url(_ raw: String) -> URL? {
        URL(string: raw.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D"))
    }

    /// A navigation out of our origin is a click the page could not report: honoured only after a touch;
    /// without one it is a forced redirect and goes nowhere.
    func externalNavigation(to target: URL) {
        guard state == .shown, Self.isAllowed(target), consumeTouch() else {
            Logger.warning("frame \(adId.prefix(8)): navigation to \(Logger.describe(target)) cancelled")
            return
        }
        onEvent?(.click(url: target, fallbackUrl: nil, area: .creative))
    }
}

// MARK: - WKNavigationDelegate

extension FrameBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else if isSameOrigin(target) {
            decisionHandler(.allow)
        } else if target.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            externalNavigation(to: target)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        // No downloads: only what the WebView can render itself.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard state == .loading else { return }
        Logger.warning("frame \(adId.prefix(8)): page failed to load, \(error.localizedDescription)")
        fail(.error(code: loadErrorCode))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.warning("frame \(adId.prefix(8)): web content process terminated")
        fail(.error(code: state == .loading ? loadErrorCode : 405))
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

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        completionHandler()
    }

    // The `async` form of the same method: the completion-handler form's closure type differs between the
    // iOS 18 and iOS 26 SDKs, and a signature that misses is never called.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(nil)
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
