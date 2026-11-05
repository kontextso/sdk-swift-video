import UIKit
import WebKit

/// A web view locked down for one ad: what the page may and may not do.
///
/// May: run its scripts, play inline media without a tap, post messages to the `kontext` handler, and load from
/// the schemes the SDK serves. May not: keep anything (a non-persistent store per ad), open windows (a
/// `target="_blank"` link goes to `onNewWindow`, which treats it as any navigation out), show dialogs (answered
/// at once, as dismissed), reach the camera or microphone (denied; on iOS 14, where WebKit asks the viewer
/// directly, the capture API is taken out of the page), leave for Picture in Picture or AirPlay, scroll, bounce
/// or preview links. A touch is noted (`onTouch`) without being taken from the page.
///
/// `FrameBridge` owns one and keeps the rest: the navigation delegate, the messages both ways, the load and its
/// timeout, the failures and the teardown.
@MainActor
final class FrameWebView: WKWebView {
    /// The name the page posts to: `window.webkit.messageHandlers.kontext`.
    static let messageHandlerName = "kontext"

    /// A message the page posted.
    var onMessage: ((WKScriptMessage) -> Void)?
    /// The viewer touched the page.
    var onTouch: (() -> Void)?
    /// The page asked for a new window to this URL.
    var onNewWindow: ((URL) -> Void)?

    private let messageHandler = MessageHandler()
    private let touchRecognizer = TouchRecognizer()

    /// `asksBeforeMediaCapture`: whether WebKit asks the UI delegate before a capture (iOS 15 on); without it the
    /// capture API is removed from the page. `schemeHandlers`: the custom schemes the page may load from.
    init(asksBeforeMediaCapture: Bool, schemeHandlers: [String: WKURLSchemeHandler]) {
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
        configuration.userContentController.add(messageHandler, name: Self.messageHandlerName)
        if !asksBeforeMediaCapture {
            configuration.userContentController.addUserScript(Self.noMediaCapture)
        }
        for (scheme, handler) in schemeHandlers {
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        super.init(frame: .zero, configuration: configuration)

        messageHandler.webView = self
        isOpaque = false
        backgroundColor = .clear
        scrollView.isScrollEnabled = false
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        allowsLinkPreview = false
        allowsBackForwardNavigationGestures = false
        uiDelegate = self
        touchRecognizer.onTouch = { [weak self] in self?.onTouch?() }
        addGestureRecognizer(touchRecognizer)
        #if DEBUG
        if #available(iOS 16.4, *) {
            isInspectable = true
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
}

// MARK: - WKUIDelegate: every request refused

extension FrameWebView: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A `target="_blank"` link: no new window, treated like any other navigation out.
        if let target = navigationAction.request.url {
            onNewWindow?(target)
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
    weak var webView: FrameWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            webView?.onMessage?(message)
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
