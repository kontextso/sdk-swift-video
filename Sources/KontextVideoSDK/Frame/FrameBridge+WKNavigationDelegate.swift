import Foundation
import WebKit

/// The page's navigations as WebKit reports them: each top-level one is decided by `FrameProtocol` (allowed,
/// cancelled, or an external click), an error status or a failed load fails the ad while it loads, a new document
/// after the page was ready ends it, and the web content process's end fails it.
extension FrameBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // No target frame: a new window (`target="_blank"`), asked here before `createWebViewWith`. Not the page
        // replacing itself, whatever its origin, and never a load failure: a navigation out, and no window.
        guard let frame = navigationAction.targetFrame else {
            decisionHandler(.cancel)
            externalNavigation(to: target)
            return
        }
        let type = navigationAction.navigationType
        let isSubmission = type == .formSubmitted || type == .formResubmitted
            || (navigationAction.request.httpMethod ?? "GET").uppercased() != "GET"
        switch frameProtocol.navigationDecision(to: target, isMainFrame: frame.isMainFrame,
                                                  isReload: type == .reload, isSubmission: isSubmission, current: webView.url) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            Logger.warning("frame \(adId.prefix(8)): the page tried to replace itself after it was ready; refused")
            decisionHandler(.cancel)
        case .external:
            decisionHandler(.cancel)
            externalNavigation(to: target)
        case .failLoad:
            decisionHandler(.cancel)
            redirectedWhileLoading(to: target)
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
            fail(.error(code: frameProtocol.loadErrorCode), cause: .loadFailed, underlying: ErrorReport.Cause(httpStatus: status))
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
        fail(.error(code: frameProtocol.loadErrorCode), cause: .loadFailed, underlying: ErrorReport.Cause(error))
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
