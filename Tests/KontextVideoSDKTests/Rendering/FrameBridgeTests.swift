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

    @Test func aNonsensePlayheadFromThePageIsClamped() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        shown(bridge)
        bridge.receive(message("video.start", ["playhead": 9_223_372_036_854_775_807]), from: main)
        guard case .video(_, let huge) = recorder.last else { Issue.record("expected video"); return }
        #expect(huge == 86_400_000, "a day at most")
        bridge.receive(message("video.pause", ["playhead": -7]), from: main)
        guard case .video(_, let negative) = recorder.last else { Issue.record("expected video"); return }
        #expect(negative == 0)
        bridge.receive(message("video.resume", ["playhead": 1e300]), from: main)
        guard case .video(_, let double) = recorder.last else { Issue.record("expected video"); return }
        #expect(double == 86_400_000, "a Double beyond Int saturates, then clamps")
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
        #expect(await waitUntil(5) { !recorder.events.isEmpty })
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

    @Test func aRefusedFallbackIsDroppedAndTheClickStays() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.noteTouch()
        bridge.receive(message("ad.click", ["url": "https://brand.test/offer", "fallbackUrl": "intent://x"]), from: main)
        guard case .click(let url, let fallback, _) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.host == "brand.test" && fallback == nil, "the fallback is opened under the same policy as the URL")
    }

    @Test func schemesThatAreNotLinksAreRefused() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        for raw in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "blob:https://x/y", "about:blank"] {
            bridge.noteTouch()
            bridge.receive(message("ad.click", ["url": raw]), from: main)
        }
        #expect(recorder.events.count == 1, "\(recorder.events)")
        bridge.noteTouch()
        bridge.receive(message("ad.click", ["url": "itms-apps://apps.apple.com/app/id1"]), from: main)
        #expect(recorder.events.count == 2, "store links open")
    }

    @Test func oneTouchOpensOneURL() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.noteTouch()
        bridge.receive(message("ad.click", ["url": "https://brand.test/offer"]), from: main)
        bridge.externalNavigation(to: URL(string: "https://brand.test/offer")!)
        bridge.receive(message("ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"]), from: main)
        #expect(recorder.events.count == 2, "the tap was spent by the click: \(recorder.events)")
        bridge.noteTouch()
        bridge.externalNavigation(to: URL(string: "https://brand.test/other")!)
        #expect(recorder.events.count == 3, "a new tap opens again")
    }

    @Test func aRedirectWithTheExplicitDefaultPortIsTheSameOrigin() {
        let (https, _) = makeBridge(url: URL(string: "https://server.kontext.so/frame/ad-1")!)
        #expect(https.isSameOrigin(URL(string: "https://server.kontext.so:443/frame/ad-1/next")!))
        #expect(https.isSameOrigin(URL(string: "https://server.kontext.so/other")!))
        #expect(!https.isSameOrigin(URL(string: "https://server.kontext.so:8443/frame/ad-1")!))
        #expect(!https.isSameOrigin(URL(string: "http://server.kontext.so/frame/ad-1")!))
        #expect(!https.isSameOrigin(URL(string: "https://evil.test/frame/ad-1")!))
        let (local, _) = makeBridge(url: URL(string: "http://localhost:5175/frame/ad-1")!)
        #expect(local.isSameOrigin(URL(string: "http://localhost:5175/x")!))
        #expect(!local.isSameOrigin(URL(string: "http://localhost/x")!))
    }

    @Test func aProcessTerminationWhileLiveFailsTheAd() {
        let (loading, loadingEvents) = makeBridge(isVideo: true)
        loading.load()
        loading.webViewWebContentProcessDidTerminate(loading.webView)
        guard case .error(let code)? = loadingEvents.last else { Issue.record("expected an error"); return }
        #expect(code == 400 && loading.state == .ended, "before it loaded: the load error code")
        let (shownBridge, shownEvents) = makeBridge()
        shown(shownBridge)
        shownBridge.webViewWebContentProcessDidTerminate(shownBridge.webView)
        guard case .error(let late)? = shownEvents.last else { Issue.record("expected an error"); return }
        #expect(late == 405 && shownBridge.state == .ended, "on screen: 405")
    }

    @Test func aTouchTooLongAgoAuthorizesNothing() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        let before = recorder.events.count
        bridge.noteTouch()
        advanceClock(by: FrameBridge.touchWindow + 0.5)
        bridge.receive(message("ad.click", ["url": "https://brand.test"]), from: main)
        bridge.externalNavigation(to: URL(string: "https://brand.test")!)
        #expect(recorder.events.count == before, "an expired touch opens nothing")
        bridge.noteTouch()
        advanceClock(by: FrameBridge.touchWindow - 0.1)
        bridge.receive(message("ad.click", ["url": "https://brand.test"]), from: main)
        #expect(recorder.events.count == before + 1, "a touch within the window still does")
    }

    @Test func aMalformedProgressOffsetIsDropped() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        shown(bridge)
        let before = recorder.events.count
        for offset in [1e300, -5, 2.5, Double.infinity, 86_400_001] as [Double] {
            bridge.receive(message("video.progress", ["offset": offset, "playhead": 0]), from: main)
        }
        bridge.receive(message("video.progress", ["offset": "5000", "playhead": 0]), from: main)
        #expect(recorder.events.count == before, "no progress event from a malformed offset")
        bridge.receive(message("video.progress", ["offset": 5000, "playhead": 5000]), from: main)
        guard case .progress(let offset, _)? = recorder.last else { Issue.record("expected progress"); return }
        #expect(offset == 5000, "a valid checkpoint still works")
    }

    @Test func originsCompareWithoutCase() {
        let (bridge, _) = makeBridge(url: URL(string: "HTTPS://Server.Kontext.SO/frame/ad-1")!)
        #expect(bridge.isFrameOrigin(main), "WebKit reports the canonical lowercase origin")
        #expect(bridge.isSameOrigin(URL(string: "https://server.kontext.so:443/next")!))
        let (local, _) = makeBridge(url: URL(string: "HTTP://LOCALHOST:5175/frame/ad-1")!)
        #expect(local.isFrameOrigin(FrameBridge.Sender(isMainFrame: true, scheme: "http", host: "localhost", port: 5175)))
        #expect(local.isSameOrigin(URL(string: "http://localhost:5175/x")!))
        let (plain, _) = makeBridge(url: URL(string: "HTTP://LOCALHOST/frame/ad-1")!)
        #expect(plain.isSameOrigin(URL(string: "http://localhost:80/x")!), "the default port, whatever the scheme's case")
        #expect(!bridge.isSameOrigin(URL(string: "https://other.kontext.so/x")!) && !bridge.isSameOrigin(URL(string: "http://server.kontext.so/x")!), "a different host or scheme is still another origin")
        #expect(!bridge.isSameOrigin(URL(string: "https://server.kontext.so:8443/x")!), "and a different port")
    }

    @Test func navigationsBeforeAndAfterThePageIsReady() {
        let (bridge, _) = makeBridge()
        let page = URL(string: "https://server.kontext.so/frame/ad-1")!
        let decide = { (target: String, mainFrame: Bool) in bridge.navigationDecision(to: URL(string: target)!, isMainFrame: mainFrame, current: page) }
        // Loading: its own origin (redirects) and about:blank go through; elsewhere is a click.
        #expect(decide("https://server.kontext.so/frame/ad-1/v2", true) == .allow)
        #expect(decide("about:blank", true) == .allow)
        #expect(decide("https://brand.test/", true) == .external)
        shown(bridge)
        // Ready: the document stays.
        #expect(decide("https://server.kontext.so/frame/ad-1#endcard", true) == .allow, "a fragment, within the document")
        #expect(decide("https://server.kontext.so/frame/other", true) == .cancel, "a same-origin page would replace the creative")
        #expect(decide("about:blank", true) == .cancel, "and so would a blank page")
        #expect(decide("https://brand.test/", true) == .external)
        #expect(decide("https://anything.test/creative", false) == .allow, "the creative's own iframe navigates freely")
    }

    @Test func aParkedBridgeReleasedWithoutAnEndLeavesNothingInTheWindow() {
        let window = TestWindow()
        defer { window.tearDown() }
        Environment.parkingWindow = { window.window }
        let webViews = { window.window.subviews.filter { $0 is WKWebView }.count }
        let before = webViews()
        do {
            let (bridge, _) = makeBridge()
            bridge.load()
            #expect(webViews() == before + 1, "parked while it loads")
        }
        #expect(webViews() == before, "dropping the bridge takes its WebView out of the window")
    }

    @Test func aProcessTerminationAfterTheEndReportsNothing() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.hide()
        let before = recorder.events.count
        bridge.webViewWebContentProcessDidTerminate(bridge.webView)
        #expect(recorder.events.count == before && bridge.state == .ended)
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

    @Test func anOpenWithoutAPurposeIsUnknownAndAnUnfamiliarOneIsKept() {
        let (bridge, recorder) = makeBridge()
        shown(bridge)
        bridge.noteTouch()
        bridge.receive(message("ad.open", ["url": "https://privacy.test"]), from: main)
        guard case .open(_, let missing) = recorder.last else { Issue.record("expected open"); return }
        #expect(missing == "unknown")
        bridge.noteTouch()
        bridge.receive(message("ad.open", ["url": "https://privacy.test", "purpose": "whyThisAd"]), from: main)
        guard case .open(_, let unfamiliar) = recorder.last else { Issue.record("expected open"); return }
        #expect(unfamiliar == "whyThisAd", "passed through unchanged")
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

    @Test func pagesParkInTheKeyWindowUnlessToldOtherwise() {
        let window = TestWindow()
        defer { window.tearDown() }
        Environment.keyWindow = { window.window }
        #expect(Environment.parkingWindow() === window.window, "by default the parking window is the key window")
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
