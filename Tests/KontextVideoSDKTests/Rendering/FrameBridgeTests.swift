import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit
import WebKit

/// The Kontext Frame Protocol as the bridge enforces it: which message is accepted in which state, from
/// whom, and what the SDK gets out of it. Messages are fed to `receive(_:from:)` directly; the page's
/// real transport is covered by the integration suite.
extension SerialSuites {
@Suite
@MainActor
struct FrameBridgeTests {
    private let url = URL(string: "https://server.kontext.so/frame/ad-1")!
    private let main = FrameBridge.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 0)

    init() { SDKHarness.reset() }

    private func makeBridge(isVideo: Bool = false, url: URL? = nil) -> (FrameBridge, Recorder) {
        let bridge = FrameBridge(adId: "ad-1", url: url ?? self.url, isVideo: isVideo)
        let recorder = Recorder()
        bridge.onEvent = { recorder.events.append($0) }
        return (bridge, recorder)
    }

    final class Recorder {
        var events: [FrameEvent] = []
        var last: FrameEvent? { events.last }
    }

    private func message(_ type: String, _ extra: [String: Any] = [:], adId: String = "ad-1") -> [String: Any] {
        var body: [String: Any] = ["adId": adId, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        return body
    }

    /// `ad.loaded` then `ad.show`: the state most messages need.
    private func shown(_ bridge: FrameBridge) {
        bridge.receive(message("ad.loaded"), from: main)
        bridge.show()
    }

    // MARK: Envelope and sender

    @Test func loadedMovesLoadingToLoaded() {
        let (bridge, recorder) = makeBridge()
        #expect(bridge.state == .loading)
        bridge.receive(message("ad.loaded"), from: main)
        #expect(bridge.state == .loaded)
        #expect(recorder.events.count == 1)
        guard case .loaded = recorder.last else { Issue.record("expected loaded"); return }
    }

    @Test func messagesWithAnotherAdIdAreDropped() {
        let (bridge, recorder) = makeBridge()
        bridge.receive(message("ad.loaded", adId: "ad-2"), from: main)
        #expect(bridge.state == .loading)
        #expect(recorder.events.isEmpty)
    }

    @Test func malformedBodiesAreDropped() {
        let (bridge, recorder) = makeBridge()
        bridge.receive("ad.loaded", from: main)
        bridge.receive(["adId": "ad-1"], from: main)
        bridge.receive(["type": "ad.loaded"], from: main)
        #expect(recorder.events.isEmpty)
    }

    @Test func messagesFromASubframeAreDropped() {
        let (bridge, recorder) = makeBridge()
        bridge.receive(message("ad.loaded"), from: FrameBridge.Sender(isMainFrame: false, scheme: "https", host: "server.kontext.so", port: 0))
        #expect(recorder.events.isEmpty)
    }

    @Test func messagesFromAnotherOriginAreDropped() {
        let (bridge, recorder) = makeBridge()
        bridge.receive(message("ad.loaded"), from: FrameBridge.Sender(isMainFrame: true, scheme: "https", host: "evil.test", port: 0))
        bridge.receive(message("ad.loaded"), from: FrameBridge.Sender(isMainFrame: true, scheme: "http", host: "server.kontext.so", port: 0))
        #expect(recorder.events.isEmpty)
    }

    @Test func originCheckTreatsPortZeroAsTheDefaultPort() {
        let (https, _) = makeBridge()
        #expect(https.isFrameOrigin(FrameBridge.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 0)))
        #expect(https.isFrameOrigin(FrameBridge.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 443)))
        #expect(!https.isFrameOrigin(FrameBridge.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 8443)))

        let (local, _) = makeBridge(url: URL(string: "http://localhost:5175/frame/ad-1")!)
        #expect(local.isFrameOrigin(FrameBridge.Sender(isMainFrame: true, scheme: "http", host: "localhost", port: 5175)))
        #expect(!local.isFrameOrigin(FrameBridge.Sender(isMainFrame: true, scheme: "http", host: "localhost", port: 0)))

        let (custom, _) = makeBridge(url: URL(string: "kontext-test://frames/frame/ad-1")!)
        #expect(custom.isFrameOrigin(FrameBridge.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)))
    }

    @Test func unknownTypesAreDropped() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.receive(message("ad.whatever"), from: main)
        #expect(recorder.events.count == 1)
    }

    // MARK: Order

    @Test func loadedIsAcceptedOnlyWhileLoading() {
        let (bridge, recorder) = makeBridge()
        bridge.receive(message("ad.loaded"), from: main)
        bridge.receive(message("ad.loaded"), from: main)
        #expect(recorder.events.count == 1)
    }

    @Test func showRequiresLoaded() {
        let (bridge, _) = makeBridge()
        bridge.show()
        #expect(bridge.state == .loading, "show before loaded is ignored")
        bridge.receive(message("ad.loaded"), from: main)
        bridge.show()
        #expect(bridge.state == .shown)
    }

    @Test func videoEventsRequireShown() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        bridge.receive(message("ad.loaded"), from: main)
        bridge.receive(message("video.start", ["playhead": 0]), from: main)
        bridge.receive(message("video.complete", ["playhead": 10_000]), from: main)
        bridge.receive(message("ad.close", ["reason": "close"]), from: main)
        bridge.receive(message("video.skip", ["playhead": 1000]), from: main)
        #expect(recorder.events.count == 1, "only loaded; the rest came before show")
        #expect(bridge.state == .loaded)
    }

    @Test func videoEventsCarryTheirNameAndPlayhead() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        shown(bridge)
        for event in FrameEvent.VideoEvent.allCases {
            bridge.receive(message("video.\(event.rawValue)", ["playhead": 1234]), from: main)
            guard case .video(let got, let playhead) = recorder.last else { Issue.record("expected video for \(event)"); continue }
            #expect(got == event)
            #expect(playhead == 1234)
        }
        let before = recorder.events.count
        bridge.receive(message("video.buffering", ["playhead": 1234]), from: main)
        #expect(recorder.events.count == before, "a video moment the SDK does not know is ignored")
    }

    @Test func progressCarriesTheOffset() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        shown(bridge)
        bridge.receive(message("video.progress", ["offset": 5000, "playhead": 5010]), from: main)
        guard case .progress(let offset, let playhead) = recorder.last else { Issue.record("expected progress"); return }
        #expect(offset == 5000)
        #expect(playhead == 5010)
        bridge.receive(message("video.progress", ["playhead": 5010]), from: main)
        #expect(recorder.events.count == 2, "loaded and one progress; the one without an offset is dropped")
    }

    @Test func completeDoesNotEndThePage() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        shown(bridge)
        bridge.receive(message("video.complete", ["playhead": 10_000]), from: main)
        guard case .complete(let playhead) = recorder.last else { Issue.record("expected complete"); return }
        #expect(playhead == 10_000)
        #expect(bridge.state == .shown, "the end card may follow")
    }

    @Test func closeEndsThePageWithTheReason() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.receive(message("ad.close", ["reason": "resume"]), from: main)
        guard case .close(let reason) = recorder.last else { Issue.record("expected close"); return }
        #expect(reason == .resume)
        #expect(bridge.state == .ended)
        bridge.receive(message("ad.close"), from: main)
        #expect(recorder.events.count == 2, "nothing after ended")
    }

    @Test func closeWithoutAReasonOrWithAnUnknownOneReadsAsClose() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.receive(message("ad.close"), from: main)
        guard case .close(let reason) = recorder.last else { Issue.record("expected close"); return }
        #expect(reason == .close)
        let (other, otherRecorder) = makeBridge()
        shown(other)
        other.receive(message("ad.close", ["reason": "swipe"]), from: main)
        guard case .close(let unknown) = otherRecorder.last else { Issue.record("expected close"); return }
        #expect(unknown == .close, "a reason the SDK does not know is a plain close")
    }

    @Test func skipEndsThePage() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        shown(bridge)
        bridge.receive(message("video.skip", ["playhead": 4321]), from: main)
        guard case .skip(let playhead) = recorder.last else { Issue.record("expected skip"); return }
        #expect(playhead == 4321)
        #expect(bridge.state == .ended)
    }

    // MARK: Errors and timeouts

    @Test func errorBeforeLoadedUsesTheLoadCodeWhenThePageGivesNone() {
        let (image, imageRecorder) = makeBridge(isVideo: false)
        image.receive(message("ad.error"), from: main)
        guard case .error(let code) = imageRecorder.last else { Issue.record("expected error"); return }
        #expect(code == 500, "NonLinear general code")
        #expect(image.state == .ended)

        let (video, videoRecorder) = makeBridge(isVideo: true)
        video.receive(message("ad.error"), from: main)
        guard case .error(let videoCode) = videoRecorder.last else { Issue.record("expected error"); return }
        #expect(videoCode == 400, "Linear general code")
    }

    @Test func errorAfterShowDefaultsTo405AndKeepsThePagesCode() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        shown(bridge)
        bridge.receive(message("ad.error"), from: main)
        guard case .error(let code) = recorder.last else { Issue.record("expected error"); return }
        #expect(code == 405)

        let (other, otherRecorder) = makeBridge(isVideo: true)
        shown(other)
        other.receive(message("ad.error", ["code": 403]), from: main)
        guard case .error(let given) = otherRecorder.last else { Issue.record("expected error"); return }
        #expect(given == 403)
    }

    @Test func loadTimeoutFailsWithTheGeneralCode() async {
        FrameBridge.loadTimeout = 0.1
        let (bridge, recorder) = makeBridge(isVideo: true)
        bridge.load()
        #expect(await waitUntil(1) { !recorder.events.isEmpty })
        guard case .error(let code) = recorder.last else { Issue.record("expected error"); return }
        #expect(code == 400)
        #expect(bridge.state == .ended)
    }

    @Test func loadedBeforeTheTimeoutCancelsIt() async {
        FrameBridge.loadTimeout = 0.1
        let (bridge, recorder) = makeBridge()
        bridge.load()
        bridge.receive(message("ad.loaded"), from: main)
        await sleepMs(200)
        #expect(recorder.events.count == 1)
        #expect(bridge.state == .loaded)
    }

    // MARK: Clicks and opens

    @Test func clickNeedsAShownPageAndARecentTouch() {
        let (bridge, recorder) = makeBridge()
        bridge.receive(message("ad.loaded"), from: main)
        bridge.noteTouch()
        bridge.receive(message("ad.click", ["url": "https://brand.test", "area": "creative"]), from: main)
        #expect(recorder.events.count == 1, "not shown yet")
        bridge.show()
        bridge.receive(message("ad.click", ["url": "https://brand.test", "area": "creative"]), from: main)
        guard case .click(let url, let fallback, let area) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.absoluteString == "https://brand.test")
        #expect(fallback == nil)
        #expect(area == .creative)
    }

    @Test func clickWithoutATouchIsDropped() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.receive(message("ad.click", ["url": "https://brand.test"]), from: main)
        #expect(recorder.events.count == 1, "a click the viewer did not make is a forced redirect")
    }

    @Test func clickKeepsTheFallbackAndDefaultsTheArea() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.noteTouch()
        bridge.receive(message("ad.click", ["url": "brandapp://offer", "fallbackUrl": "https://brand.test/offer"]), from: main)
        guard case .click(let url, let fallback, let area) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.scheme == "brandapp", "deep links are allowed")
        #expect(fallback?.host == "brand.test")
        #expect(area == .creative)
    }

    @Test func intentSchemeIsRefused() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.noteTouch()
        bridge.receive(message("ad.click", ["url": "intent://scan/#Intent;scheme=zxing;end"]), from: main)
        bridge.receive(message("ad.open", ["url": "INTENT://x", "purpose": "adChoices"]), from: main)
        #expect(recorder.events.count == 1)
    }

    @Test func openCarriesThePurposeAndIsNotAClick() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.noteTouch()
        bridge.receive(message("ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"]), from: main)
        guard case .open(let url, let purpose) = recorder.last else { Issue.record("expected open"); return }
        #expect(url.host == "adchoices.test")
        #expect(purpose == "adChoices")
    }

    @Test func invalidURLsAreDropped() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.noteTouch()
        bridge.receive(message("ad.click", ["url": 42]), from: main)
        bridge.receive(message("ad.click", ["url": ""]), from: main)
        #expect(recorder.events.count == 1)
    }

    // MARK: SDK → page

    @Test func showSendsAdShowAndHideSendsAdHideOnlyWhenShown() {
        let (bridge, _) = makeBridge()
        var sent: [String] = []
        bridge.onSend = { type, _ in sent.append(type) }
        bridge.receive(message("ad.loaded"), from: main)
        bridge.hide()
        #expect(sent.isEmpty, "a page that was never shown gets no ad.hide")
        #expect(bridge.state == .ended)

        let (second, _) = makeBridge()
        var sentSecond: [String] = []
        second.onSend = { type, _ in sentSecond.append(type) }
        shown(second)
        second.hide()
        #expect(sentSecond == ["ad.show", "ad.hide"])
    }

    @Test func exposureIsSentOnlyWhileShown() {
        let (bridge, _) = makeBridge()
        var payloads: [[String: Any]] = []
        bridge.onSend = { type, payload in if type == "ad.exposure" { payloads.append(payload) } }
        bridge.exposure(percentage: 1, visibleRectangle: .zero)
        #expect(payloads.isEmpty)
        shown(bridge)
        bridge.exposure(percentage: 0.5, visibleRectangle: CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(payloads.count == 1)
        #expect(payloads[0]["exposedPercentage"] as? Double == 0.5)
        let rect = payloads[0]["visibleRectangle"] as? [String: CGFloat]
        #expect(rect?["x"] == 1 && rect?["width"] == 3)
    }

    @Test func envelopeIsTheProtocolsShape() throws {
        let json = try #require(FrameBridge.envelope(adId: "ad-1", type: "ad.exposure", payload: ["exposedPercentage": 0.75]))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["adId"] as? String == "ad-1")
        #expect(object?["type"] as? String == "ad.exposure")
        #expect(object?["exposedPercentage"] as? Double == 0.75)
    }

    // MARK: Parking

    @Test func loadParksTheWebViewInTheKeyWindowAndTakeWebViewUnparksIt() {
        let window = TestWindow()
        defer { window.tearDown() }
        Environment.keyWindow = { window.window }
        let (bridge, _) = makeBridge()
        bridge.load()
        #expect(bridge.webView.superview === window.window)
        #expect(bridge.webView.alpha == 0)
        #expect(bridge.webView.isUserInteractionEnabled == false)
        let webView = bridge.takeWebView()
        #expect(webView === bridge.webView)
        #expect(webView.superview == nil)
        #expect(webView.alpha == 1)
        #expect(webView.isUserInteractionEnabled)
    }

    @Test func endingUnparksTheWebView() {
        let window = TestWindow()
        defer { window.tearDown() }
        Environment.keyWindow = { window.window }
        let (bridge, _) = makeBridge()
        bridge.load()
        bridge.hide()
        #expect(bridge.webView.superview == nil, "nothing stays in the window after the ad is gone")
    }

    @Test func withoutAKeyWindowLoadStillWorks() {
        Environment.keyWindow = { nil }
        let (bridge, _) = makeBridge()
        bridge.load()
        #expect(bridge.webView.superview == nil)
        #expect(bridge.state == .loading)
    }

    // MARK: Configuration

    @Test func webViewIsLockedDown() {
        let (bridge, _) = makeBridge()
        let configuration = bridge.webView.configuration
        #expect(configuration.websiteDataStore.isPersistent == false)
        #expect(configuration.allowsInlineMediaPlayback)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(bridge.webView.scrollView.isScrollEnabled == false)
        #expect(bridge.webView.allowsLinkPreview == false)
        #expect(bridge.webView.isOpaque == false)
    }
}
}
