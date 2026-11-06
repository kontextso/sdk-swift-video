import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit
import WebKit

/// The bridge as the shell around `FrameProtocol`: it carries out each step (a few messages fed to
/// `receive(_:from:)` directly), and owns what needs WebKit: the load and its timeout, the navigation and
/// process callbacks, the messages to the page, parking, the WebView's configuration. The protocol's rules one
/// by one are `FrameProtocolTests`, without a WebView; the page's real transport is the integration suite's.
extension SerialSuites {
@Suite
@MainActor
struct FrameBridgeTests {
    private let url = URL(string: "https://server.kontext.so/frame/ad-1")!
    private let main = FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 0)

    init() { SDKHarness.reset() }

    private func makeBridge(isVideo: Bool = false, url: URL? = nil, videoDuration: TimeInterval? = nil) -> (FrameBridge, Recorder) {
        let bridge = FrameBridge(adId: "ad-1", url: url ?? self.url, isVideo: isVideo, videoDuration: videoDuration)
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

    // MARK: The protocol's steps, carried out

    @Test func loadedMovesLoadingToLoaded() {
        let (bridge, recorder) = makeBridge()
        #expect(bridge.state == .loading)
        bridge.receive(message("ad.loaded"), from: main)
        #expect(bridge.state == .loaded)
        #expect(recorder.events.count == 1)
        guard case .loaded = recorder.last else { Issue.record("expected loaded"); return }
    }

    /// `message` as the page posts it: `JSON.stringify(message)`.
    private func json(_ type: String, _ extra: [String: Any] = [:], adId: String = "ad-1") -> String {
        String(data: try! JSONSerialization.data(withJSONObject: message(type, extra, adId: adId)), encoding: .utf8)!
    }

    @Test func aMessagePostedAsAJSONStringIsTheSameMessage() {
        let (bridge, recorder) = makeBridge(isVideo: true)
        bridge.receive(json("ad.loaded"), from: main)
        #expect(bridge.state == .loaded)
        bridge.show()
        bridge.receive(json("video.start", ["playhead": 0]), from: main)
        guard case .video(.start, 0)? = recorder.last else { Issue.record("expected video.start, got \(String(describing: recorder.last))"); return }
        bridge.receive(json("video.progress", ["offset": 5000, "playhead": 5010]), from: main)
        guard case .progress(5000, 5010)? = recorder.last else { Issue.record("expected progress"); return }
        bridge.noteTouch()
        bridge.receive(json("ad.click", ["url": "https://brand.test/landing", "area": "cta"]), from: main)
        guard case .click(let url, _, _)? = recorder.last else { Issue.record("expected click"); return }
        #expect(url.absoluteString == "https://brand.test/landing")
        bridge.receive(json("ad.loaded", adId: "ad-2"), from: main)
        #expect(recorder.events.count == 4, "the same checks: another ad's id is dropped")
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

    // MARK: Load timeout

    @Test func loadTimeoutFailsWithTheGeneralCode() async {
        // The timeout counts active time only; a CI runner's test app is not always active.
        Environment.isApplicationActive = { true }
        FrameBridge.loadTimeout = 0.1
        let (bridge, recorder) = makeBridge(isVideo: true)
        bridge.load()
        #expect(await waitUntil { !recorder.events.isEmpty })
        guard case .error(let code) = recorder.last else { Issue.record("expected error"); return }
        #expect(code == 400)
        #expect(bridge.state == .ended)
    }

    @Test func aSuspensionBetweenTwoActiveTicksDoesNotTimeTheLoadOut() async {
        FrameBridge.loadTimeout = 5
        let (bridge, events) = makeBridge()
        bridge.load()
        await sleepMs(300)
        advanceClock(by: 600)   // ten minutes suspended, active at the tick before and the tick after
        await sleepMs(600)
        // The page itself may fail to load meanwhile (no network here); what counts is that no timeout did.
        #expect(bridge.failureCause != .loadTimeout, "a load is not timed out by the background gap: \(events.events)")
        bridge.hide()
    }

    @Test func aSuspensionNearTheDeadlineDoesNotTimeTheLoadOut() async {
        Environment.isApplicationActive = { true }
        FrameBridge.loadTimeout = 2.6
        // A page that loads and never reports ready (`dead-`): only the timeout can end it.
        FramePageServer().install()
        // The clock stands still but for the steps below: the ticks count only those, however late they run.
        let frozen = Environment.now()
        Environment.now = { frozen }
        let (bridge, events) = makeBridge(url: URL(string: "\(Fixtures.frameOrigin)/frame/dead-2")!)
        bridge.load()
        await sleepMs(100)   // the timeout's task starts on the main actor, at the frozen time
        advanceClock(by: 0.9)
        await sleepMs(400)
        // Suspended between two ticks that both find the app active; it comes back with the activation notice.
        advanceClock(by: 600)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await sleepMs(400)
        advanceClock(by: 0.6)
        await sleepMs(400)
        // At most 1.5 s of active time: counting the gap as a late tick (2 s) would have passed the 2.6 s.
        #expect(bridge.state == .loading, "the suspension counts nothing: \(events.events)")
        // The clock runs again from here: the active time still runs out.
        let resumed = Environment.now()
        let start = Date()
        Environment.now = { resumed + Date().timeIntervalSince(start) }
        #expect(await waitUntil(10) { bridge.failureCause == .loadTimeout }, "the active time still runs out")
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

    // MARK: Navigation and the web process

    @Test func aCommittedNavigationThatFailsWhileLoadingFailsTheAd() {
        let (bridge, events) = makeBridge(isVideo: true)
        bridge.load()
        bridge.webView(bridge.webView, didFail: nil, withError: URLError(.networkConnectionLost))
        guard case .error(let code)? = events.last else { Issue.record("expected an error"); return }
        #expect(code == 400 && bridge.state == .ended)
        #expect(bridge.failureUnderlying?.code == URLError.networkConnectionLost.rawValue)
    }

    @Test func aCrossOriginRedirectWhileLoadingFailsAtOnce() {
        let (bridge, events) = makeBridge()
        bridge.load()
        bridge.redirectedWhileLoading(to: URL(string: "https://other.example/x")!)
        guard case .error(let code)? = events.last else { Issue.record("expected an error, not the load timeout"); return }
        #expect(code == 500 && bridge.state == .ended && bridge.failureCause == .loadFailed)
    }

    @Test func aNewWindowWhileLoadingIsDroppedAndTheLoadGoesOn() {
        let (bridge, events) = makeBridge()
        bridge.load()
        // window.open or target=_blank, from the page or one of its frames: what `onNewWindow` hands the bridge.
        bridge.webView.onNewWindow?(URL(string: "https://popunder.example/x")!)
        #expect(bridge.state == .loading && events.events.isEmpty && bridge.failureCause == nil, "not a load failure")
        bridge.hide()
    }

    /// A `target="_blank"` link of the page's own origin, tapped while shown: WebKit asks the navigation delegate
    /// first, with no target frame. That is not the page replacing itself: it is the new window, a click, and the
    /// window itself is never created.
    @Test func aSameOriginNewWindowLinkAfterATouchIsAClick() {
        let (bridge, recorder) = makeBridge()
        bridge.load()
        shown(bridge)
        bridge.noteTouch()
        let target = URL(string: "https://server.kontext.so/landing")!
        var decision: WKNavigationActionPolicy?
        bridge.webView(bridge.webView, decidePolicyFor: NewWindowAction(target), decisionHandler: { decision = $0 })
        #expect(decision == .cancel, "no window")
        guard case .click(let url, _, _)? = recorder.last else { Issue.record("expected a click, got \(recorder.events)"); return }
        #expect(url == target && bridge.state == .shown)
        bridge.hide()
    }

    /// The same while the page loads, of any origin (a tag's popunder): dropped, and the load goes on.
    @Test func aNewWindowNavigationWhileLoadingIsDroppedAndTheLoadGoesOn() {
        let (bridge, recorder) = makeBridge()
        bridge.load()
        for target in ["https://popunder.example/x", "https://server.kontext.so/other"] {
            var decision: WKNavigationActionPolicy?
            bridge.webView(bridge.webView, decidePolicyFor: NewWindowAction(URL(string: target)!), decisionHandler: { decision = $0 })
            #expect(decision == .cancel, "\(target)")
        }
        #expect(bridge.state == .loading && recorder.events.isEmpty && bridge.failureCause == nil, "not a load failure")
        bridge.hide()
    }

    /// The real path: a page in a window taps its own `target="_blank"` link after the viewer's touch.
    @Test func aPagesSameOriginBlankLinkReachesTheBridgeAsAClick() async throws {
        FramePageServer().install()
        Environment.isApplicationActive = { true }
        Environment.parkingWindow = { ParkingWindow.window }
        FrameBridge.loadTimeout = 30
        let bridge = FrameBridge(adId: "img-blank", url: URL(string: "\(Fixtures.frameOrigin)/frame/img-blank")!, isVideo: false)
        defer { bridge.hide() }
        let recorder = Recorder()
        bridge.onEvent = { recorder.events.append($0) }
        bridge.load()
        guard await waitUntil(35, { bridge.state == .loaded }) else { Issue.record("the page never loaded"); return }
        bridge.show()
        bridge.noteTouch()
        let target = "\(Fixtures.frameOrigin)/landing"
        _ = try await bridge.webView.evaluateJavaScript("""
            var a = document.createElement('a'); a.href = '\(target)'; a.target = '_blank';
            document.body.appendChild(a); a.click(); 'ok'
            """)
        let clicked = await waitUntil(5) {
            recorder.events.contains { if case .click(let url, _, _) = $0 { return url.absoluteString == target } else { return false } }
        }
        #expect(clicked, "\(recorder.events)")
        #expect(bridge.state == .shown)
    }

    /// A navigation action for a new window: WebKit gives it no target frame.
    private final class NewWindowAction: WKNavigationAction {
        private let target: URL
        init(_ target: URL) { self.target = target }
        override var request: URLRequest { URLRequest(url: target) }
        override var targetFrame: WKFrameInfo? { nil }
        override var navigationType: WKNavigationType { .linkActivated }
    }

    @Test func navigationsStoppedOnPurposeDoNotFailTheAd() {
        let (bridge, events) = makeBridge()
        bridge.load()
        bridge.webView(bridge.webView, didFail: nil, withError: URLError(.cancelled))
        bridge.webView(bridge.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(bridge.state == .loading && events.events.isEmpty)
    }

    @Test func aFailedNavigationAfterThePageIsReadyIsIgnored() {
        let (loaded, loadedEvents) = makeBridge()
        loaded.receive(message("ad.loaded"), from: main)
        loaded.webView(loaded.webView, didFail: nil, withError: URLError(.networkConnectionLost))
        loaded.webView(loaded.webView, didFailProvisionalNavigation: nil, withError: URLError(.cannotFindHost))
        #expect(loaded.state == .loaded && loadedEvents.events.count == 1, "loaded, not yet shown: only ad.loaded")
        let (shownBridge, shownEvents) = makeBridge()
        shown(shownBridge)
        let before = shownEvents.events.count
        shownBridge.webView(shownBridge.webView, didFail: nil, withError: URLError(.networkConnectionLost))
        #expect(shownBridge.state == .shown && shownEvents.events.count == before)
    }

    @Test func aProcessTerminationWhileLiveFailsTheAd() {
        let (loading, loadingEvents) = makeBridge(isVideo: true)
        loading.load()
        loading.webViewWebContentProcessDidTerminate(loading.webView)
        guard case .error(let code)? = loadingEvents.last else { Issue.record("expected an error"); return }
        #expect(code == 400 && loading.state == .ended, "before it loaded: the load error code")
        let (loaded, loadedEvents) = makeBridge(isVideo: true)
        loaded.receive(message("ad.loaded"), from: main)
        loaded.webViewWebContentProcessDidTerminate(loaded.webView)
        guard case .error(let notShown)? = loadedEvents.last else { Issue.record("expected an error"); return }
        #expect(notShown == 400 && loaded.state == .ended, "loaded, never shown: still the load error code, not 405")
        let (shownBridge, shownEvents) = makeBridge()
        shown(shownBridge)
        shownBridge.webViewWebContentProcessDidTerminate(shownBridge.webView)
        guard case .error(let late)? = shownEvents.last else { Issue.record("expected an error"); return }
        #expect(late == 405 && shownBridge.state == .ended, "on screen: 405")
    }

    @Test func aNewDocumentAfterThePageWasReadyEndsTheAd() {
        let (loading, loadingEvents) = makeBridge()
        loading.load()
        loading.webView(loading.webView, didStartProvisionalNavigation: nil)
        loading.webView(loading.webView, didCommit: nil)
        #expect(loading.state == .loading && loadingEvents.events.isEmpty, "the page's own load and redirects")
        let (shownBridge, shownEvents) = makeBridge()
        shown(shownBridge)
        shownBridge.webView(shownBridge.webView, didStartProvisionalNavigation: nil)
        guard case .error(let code)? = shownEvents.last else { Issue.record("expected an error"); return }
        #expect(code == 405 && shownBridge.state == .ended && shownBridge.failureCause == .page)
        let (loaded, loadedEvents) = makeBridge(isVideo: true)
        loaded.receive(message("ad.loaded"), from: main)
        loaded.webView(loaded.webView, didCommit: nil)
        guard case .error(let early)? = loadedEvents.last else { Issue.record("expected an error"); return }
        #expect(early == 400 && loaded.state == .ended, "ready, not yet shown: the load error code")
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
        bridge.exposure(percentage: 0.5, visibleRectangle: CGRect(x: 1, y: 2, width: 3, height: 4))   // a share; the page gets 0–100
        #expect(payloads.count == 1)
        #expect(payloads[0]["exposedPercentage"] as? Double == 50)
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

    @Test func anEnvelopeWithANonFiniteNumberIsDroppedNotACrash() {
        // JSONSerialization raises an Objective-C exception for these, which would take the app down.
        #expect(FrameBridge.envelope(adId: "ad-1", type: "ad.exposure", payload: ["exposedPercentage": Double.nan]) == nil)
        #expect(FrameBridge.envelope(adId: "ad-1", type: "ad.exposure", payload: ["visibleRectangle": ["x": CGFloat.infinity]]) == nil)
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

    @Test func aLoadStartedInTheBackgroundParksOnceTheAppIsActiveAgain() async {
        let window = TestWindow()
        defer { window.tearDown() }
        var foreground = false
        Environment.isApplicationActive = { foreground }
        Environment.parkingWindow = { foreground ? window.window : nil }
        // A page that loads and never reports ready (`dead-`): an unreachable URL fails fast on some iOS versions
        // (15), and a page that reports ready stops the parking; the test needs it still loading on return.
        FramePageServer().install()
        let (bridge, _) = makeBridge(isVideo: true, url: URL(string: "\(Fixtures.frameOrigin)/frame/dead-1")!)
        bridge.load()
        await sleepMs(300)
        #expect(bridge.webView.superview == nil, "no window to park in while in the background")
        #expect(bridge.state == .loading)
        foreground = true
        #expect(await waitUntil { bridge.webView.superview === window.window }, "parked on return, so the video can buffer")
        #expect(bridge.webView.alpha == 0 && bridge.webView.isUserInteractionEnabled == false)
        bridge.hide()
        #expect(bridge.webView.superview == nil)
    }

    // MARK: Configuration

    @Test func theCaptureAPIIsRemovedOnlyWhereWebKitCannotAskTheDelegate() {
        Environment.asksBeforeMediaCapture = { true }
        #expect(makeBridge().0.webView.configuration.userContentController.userScripts.isEmpty, "iOS 15 on: the delegate denies")

        Environment.asksBeforeMediaCapture = { false }
        let scripts = makeBridge().0.webView.configuration.userContentController.userScripts
        #expect(scripts.count == 1, "iOS 14")
        #expect(scripts.first?.injectionTime == .atDocumentStart, "before the page's own scripts")
        #expect(scripts.first?.isForMainFrameOnly == false, "in the creative's iframes too")
        #expect(scripts.first?.source.contains("MediaDevices.prototype.getUserMedia") == true)
        #expect(scripts.first?.source.contains("webkitGetUserMedia") == true)
    }

    @Test func theScriptTakesGetUserMediaOutOfAPage() async throws {
        FramePageServer().install()
        // Loaded in a window, as the harness does: outside one, WebKit deprioritizes the page and a CI runner
        // without a key window never finishes loading it.
        Environment.isApplicationActive = { true }
        Environment.parkingWindow = { ParkingWindow.window }
        // The bridge's own limit as the harness sets it, not the 10 s of `reset()`: a cold web content process on a
        // CI runner took longer, and the page's load is not what this test is about.
        FrameBridge.loadTimeout = 30
        let probe = "typeof MediaDevices === 'undefined' ? 'none' : typeof MediaDevices.prototype.getUserMedia"
        func readProbe(asks: Bool) async throws -> String? {
            Environment.asksBeforeMediaCapture = { asks }
            let bridge = FrameBridge(adId: "img-capture", url: URL(string: "\(Fixtures.frameOrigin)/frame/img-capture")!, isVideo: false)
            defer { bridge.hide() }
            var loaded = false
            bridge.onEvent = { if case .loaded = $0 { loaded = true } }
            bridge.load()
            // Never `evaluateJavaScript` on a page that did not load: on a stuck web process it waits for minutes.
            guard await waitUntil(35, { loaded }) else {
                Issue.record("the page never loaded")
                return nil
            }
            return try await bridge.webView.evaluateJavaScript(probe) as? String
        }
        #expect(try await readProbe(asks: true) == "function", "the control: WebKit has the API")
        #expect(try await readProbe(asks: false) == "undefined")
    }

    @Test func webViewIsLockedDown() {
        let (bridge, _) = makeBridge()
        let configuration = bridge.webView.configuration
        #expect(configuration.websiteDataStore.isPersistent == false)
        #expect(configuration.allowsInlineMediaPlayback)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
        #expect(configuration.allowsPictureInPictureMediaPlayback == false, "the ad never leaves for a PiP window")
        #expect(configuration.allowsAirPlayForMediaPlayback == false, "nor for an AirPlay screen")
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(bridge.webView.scrollView.isScrollEnabled == false)
        #expect(bridge.webView.allowsLinkPreview == false)
        #expect(bridge.webView.isOpaque == false)
    }
}
}
