import Foundation
import UIKit
import WebKit

/// What the frame page told the bridge, already checked and in order.
enum FrameEvent: Sendable {
    /// The creative is rendered and can be shown.
    case ready
    /// The viewer tapped the ad. `area` is `creative`, `cta`, `endCard`, `skoverlay` or `adChoices`.
    case click(url: URL, fallbackUrl: URL?, appStoreId: String?, area: String)
    /// The viewer dismissed the ad with the page's control. `reason` is `close`, `resume` or `unload`.
    case close(reason: String)
    /// The viewer dismissed a video before it completed.
    case skip(playhead: Int)
    /// `start`, `firstQuartile`, `midpoint`, `thirdQuartile`, `pause`, `resume`, `mute`, `unmute`.
    case video(name: String, playhead: Int)
    /// The video played to the end. The SDK fires the `complete` beacon and grants the reward.
    case complete(playhead: Int)
    /// The creative failed to load or play, with the VAST error code. The page fired the error beacon.
    case error(code: Int)
    /// The page did not answer in time, or could not be loaded. The SDK fires the error beacon.
    case loadFailed(code: Int)
}

/// Owns the WebView of one ad and speaks the Kontext Frame Protocol v2 with its page.
///
/// The page posts to the `kontext` script message handler; the bridge answers with
/// `window.postMessage` into the page. One bridge, one ad: it accepts messages only from the main frame
/// of the page it loaded, carrying its own ad id, and only in an order that makes sense.
@MainActor
final class FrameBridge: NSObject {
    enum State: Sendable {
        case loading
        case ready
        case shown
        case ended
    }

    static let loadTimeout: TimeInterval = 10
    /// A click is opened only if the viewer touched the WebView this recently.
    static let touchWindow: TimeInterval = 1
    static let allowedClickSchemes: Set<String> = ["http", "https", "itms-apps", "itms-appss", "itms", "market"]

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
        touchRecognizer.onTouch = { [weak self] in self?.lastTouchAt = ProcessInfo.processInfo.systemUptime }
        webView.addGestureRecognizer(touchRecognizer)
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
    }

    /// Loads the page. `ad.ready` must arrive within `loadTimeout`.
    func load() {
        Logger.debug("frame \(adId.prefix(8)): loading \(url)")
        webView.load(URLRequest(url: url))
        loadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.loadTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, state == .loading else { return }
            Logger.warning("frame \(adId.prefix(8)): no ad.ready within \(Int(Self.loadTimeout)) s")
            fail(.loadFailed(code: loadErrorCode))
        }
    }

    // MARK: SDK → page

    /// The page is on screen: it starts whatever the creative does when visible.
    func show(contentPlayhead: Int) {
        guard state == .ready else {
            Logger.warning("frame \(adId.prefix(8)): show() in state \(state), ignored")
            return
        }
        state = .shown
        send("ad.show", ["contentPlayhead": contentPlayhead])
    }

    /// How much of the box is on screen, from the viewability meter.
    func exposure(percentage: Double, visibleRectangle: CGRect, contentPlayhead: Int) {
        guard state == .shown else { return }
        send("ad.exposure", [
            "exposedPercentage": percentage,
            "visibleRectangle": ["x": visibleRectangle.minX, "y": visibleRectangle.minY, "width": visibleRectangle.width, "height": visibleRectangle.height],
            "contentPlayhead": contentPlayhead,
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

    private func send(_ type: String, _ payload: [String: Any] = [:]) {
        var message: [String: Any] = ["kontext": 2, "adId": adId, "type": type]
        payload.forEach { message[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.postMessage(\(json), window.location.origin)") { _, error in
            if let error { Logger.debug("frame \(self.adId.prefix(8)): \(type) not delivered, \(error.localizedDescription)") }
        }
    }

    // MARK: Page → SDK

    /// Checks the envelope, the sender and the order; drops anything else without an error.
    fileprivate func receive(_ message: WKScriptMessage) {
        guard state != .ended else { return }
        guard message.frameInfo.isMainFrame, isFrameOrigin(message.frameInfo.securityOrigin) else {
            Logger.debug("frame \(adId.prefix(8)): message from another frame dropped")
            return
        }
        guard let body = message.body as? [String: Any],
              (body["kontext"] as? NSNumber)?.intValue == 2,
              body["adId"] as? String == adId,
              let type = body["type"] as? String else {
            Logger.debug("frame \(adId.prefix(8)): malformed message dropped")
            return
        }
        Logger.debug("frame \(adId.prefix(8)): ← \(type)")
        let playhead = (body["playhead"] as? NSNumber)?.intValue ?? 0

        switch type {
        case "ad.ready":
            guard state == .loading else { return }
            loadTimeoutTask?.cancel()
            state = .ready
            onEvent?(.ready)
        case "ad.click":
            guard state == .shown, let raw = body["url"] as? String, let url = URL(string: raw) else { return }
            let area = body["area"] as? String ?? "creative"
            guard let scheme = url.scheme?.lowercased(), Self.allowedClickSchemes.contains(scheme) else {
                Logger.warning("frame \(adId.prefix(8)): click to \(raw) dropped, scheme not allowed")
                return
            }
            guard wasTouchedRecently else {
                Logger.warning("frame \(adId.prefix(8)): click to \(url.host ?? raw) dropped, no touch before it")
                return
            }
            onEvent?(.click(url: url, fallbackUrl: (body["fallbackUrl"] as? String).flatMap(URL.init(string:)), appStoreId: body["appStoreId"] as? String, area: area))
        case "ad.close":
            guard state == .shown else { return }
            end()
            onEvent?(.close(reason: body["reason"] as? String ?? "close"))
        case "video.skip":
            guard state == .shown else { return }
            end()
            onEvent?(.skip(playhead: playhead))
        case "video.complete":
            guard state == .shown else { return }
            onEvent?(.complete(playhead: playhead))
        case "video.start", "video.firstQuartile", "video.midpoint", "video.thirdQuartile", "video.pause", "video.resume", "video.mute", "video.unmute":
            guard state == .shown else { return }
            onEvent?(.video(name: String(type.dropFirst("video.".count)), playhead: playhead))
        case "ad.error":
            guard state == .loading || state == .ready || state == .shown else { return }
            fail(.error(code: (body["code"] as? NSNumber)?.intValue ?? (state == .shown ? 405 : loadErrorCode)))
        default:
            Logger.debug("frame \(adId.prefix(8)): unknown message \(type) dropped")
        }
    }

    private var wasTouchedRecently: Bool {
        ProcessInfo.processInfo.systemUptime - lastTouchAt <= Self.touchWindow
    }

    private func isFrameOrigin(_ origin: WKSecurityOrigin) -> Bool {
        let defaultPort = url.scheme == "https" ? 443 : 80
        return origin.protocol == url.scheme && origin.host == url.host && origin.port == (url.port ?? defaultPort)
    }

    private func fail(_ event: FrameEvent) {
        end()
        onEvent?(event)
    }

    /// Terminal: the page is stopped and nothing is accepted or sent any more.
    private func end() {
        guard state != .ended else { return }
        state = .ended
        loadTimeoutTask?.cancel()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kontext")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// A navigation out of our origin is a click the page could not report: honoured only after a touch.
    private func externalNavigation(to target: URL) {
        guard state == .shown, wasTouchedRecently, let scheme = target.scheme?.lowercased(), Self.allowedClickSchemes.contains(scheme) else {
            Logger.warning("frame \(adId.prefix(8)): navigation to \(target.host ?? target.absoluteString) cancelled")
            return
        }
        onEvent?(.click(url: target, fallbackUrl: nil, appStoreId: nil, area: "creative"))
    }
}

// MARK: - WKNavigationDelegate

extension FrameBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else if target.scheme == url.scheme, target.host == url.host, target.port == url.port {
            decisionHandler(.allow)
        } else if target.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            externalNavigation(to: target)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // No downloads: only what the WebView can render itself.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard state == .loading else { return }
        Logger.warning("frame \(adId.prefix(8)): page failed to load, \(error.localizedDescription)")
        fail(.loadFailed(code: loadErrorCode))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.warning("frame \(adId.prefix(8)): web content process terminated")
        fail(state == .loading ? .loadFailed(code: loadErrorCode) : .error(code: 405))
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
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
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
