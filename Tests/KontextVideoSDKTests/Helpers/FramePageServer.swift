import Foundation
@testable import KontextVideoSDK
import WebKit

/// Serves frame pages to the SDK's WebView over the `kontext-test` scheme, from inside the test process.
/// The page speaks the Kontext Frame Protocol v2 the way the real one does: it posts to the `kontext`
/// handler and listens for the host's `window.postMessage`.
///
/// Page kinds, picked by the ad id's prefix:
/// - `img-…`: sends `ad.loaded` at once; on `ad.show` it is simply visible. A click on the page's body
///   is reported with `ad.click` when the test asks for it (`?click=1`).
/// - `vid-…`: sends `ad.loaded`; on `ad.show` plays a scripted "video": `video.start`, the quartiles,
///   `video.progress` 5000, `video.complete`, every `step` ms (default 60), then waits for the end card
///   to be closed by the test (`closeEndCard()`), sending `ad.close`.
/// - `dead-…`: never sends `ad.loaded`.
/// - `err-…`: sends `ad.error` with code 502 instead of `ad.loaded`.
@MainActor
final class FramePageServer: NSObject, WKURLSchemeHandler {
    static let scheme = "kontext-test"

    /// Pages served so far, by ad id.
    private(set) var served: [String] = []

    func install() {
        Environment.schemeHandlers[Self.scheme] = self
    }

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        let adId = url.lastPathComponent
        let step = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "step" }?.value ?? "") ?? 60
        Task { @MainActor in
            served.append(adId)
        }
        let html = Self.page(adId: adId, step: step)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data(html.utf8))
        urlSchemeTask.didFinish()
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    nonisolated static func page(adId: String, step: Int) -> String {
        let kind = adId.split(separator: "-").first.map(String.init) ?? "img"
        return """
        <!doctype html><html data-ad-id="\(adId)"><head><meta name="viewport" content="width=device-width"></head>
        <body style="margin:0;background:#246;color:#fff;font:14px sans-serif">
        <div id="box" style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center">\(adId)</div>
        <script>
        var adId = "\(adId)";
        var kind = "\(kind)";
        var step = \(step);
        var shown = false, completed = false;
        function send(type, payload) {
          var m = Object.assign({ adId: adId, type: type }, payload || {});
          window.webkit.messageHandlers.kontext.postMessage(m);
        }
        window.addEventListener('message', function (e) {
          var m = e.data; if (!m || m.adId !== adId) return;
          if (m.type === 'ad.show') { shown = true; if (kind === 'vid') playVideo(); }
          if (m.type === 'ad.hide') { shown = false; }
          if (m.type === 'ad.exposure') { window.lastExposure = m.exposedPercentage; }
        });
        function playVideo() {
          var t = 0;
          var seq = [['video.start', 0], ['video.firstQuartile', 2500], ['video.midpoint', 5000],
                     ['video.progress', 5000, { offset: 5000 }], ['video.thirdQuartile', 7500], ['video.complete', 10000]];
          seq.forEach(function (s, i) {
            setTimeout(function () {
              var payload = Object.assign({ playhead: s[1] }, s[2] || {});
              send(s[0], payload);
              if (s[0] === 'video.complete') { completed = true; document.getElementById('box').textContent = 'end card'; }
            }, step * (i + 1));
          });
        }
        window.closeEndCard = function () { send('ad.close', { reason: 'close' }); };
        window.skip = function (playhead) { send('video.skip', { playhead: playhead || 1000 }); };
        window.close = function (reason) { send('ad.close', { reason: reason || 'close' }); };
        window.click = function (url, area) { send('ad.click', { url: url, area: area || 'creative' }); };
        window.open = function (url, purpose) { send('ad.open', { url: url, purpose: purpose || 'adChoices' }); };
        window.fail = function (code) { send('ad.error', { code: code || 405 }); };
        if (kind === 'dead') { /* never ready */ }
        else if (kind === 'err') { send('ad.error', { code: 502 }); }
        else { send('ad.loaded'); }
        </script></body></html>
        """
    }
}
