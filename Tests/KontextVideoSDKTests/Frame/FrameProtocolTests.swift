import Foundation
@testable import KontextVideoSDK
import Testing

/// The Kontext Frame Protocol's rules one by one, as a page meets them: which message is accepted in which state,
/// from whom, and what the SDK gets out of it. Driven through `FramePageDriver`, the bridge's calls without a
/// WebView; `FrameProtocolTableTests` holds the same rules as tables, `FrameBridgeTests` the bridge that carries
/// them out.
@Suite
@MainActor
struct FrameProtocolTests {
    private let url = URL(string: "https://server.kontext.so/frame/ad-1")!
    private let main = FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 0)

    private func makePage(isVideo: Bool = false, url: URL? = nil, videoDuration: TimeInterval? = nil) -> (FramePageDriver, Recorder) {
        let page = FramePageDriver(url: url ?? self.url, isVideo: isVideo, videoDuration: videoDuration)
        let recorder = Recorder()
        page.onEvent = { recorder.events.append($0) }
        return (page, recorder)
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

    /// `message` as the page posts it: `JSON.stringify(message)`.
    private func json(_ type: String, _ extra: [String: Any] = [:], adId: String = "ad-1") -> String {
        String(data: try! JSONSerialization.data(withJSONObject: message(type, extra, adId: adId)), encoding: .utf8)!
    }

    /// `ad.loaded` then `ad.show`: the state most messages need.
    private func shown(_ page: FramePageDriver) {
        page.receive(message("ad.loaded"), from: main)
        page.show()
    }

    /// Shown, and the page's video started: the video's progress and quartiles count only after `video.start`.
    private func started(_ page: FramePageDriver) {
        shown(page)
        page.receive(message("video.start"), from: main)
    }

    @Test func aStringThatIsNotAJSONObjectOrIsTooLongIsDropped() {
        let (page, recorder) = makePage()
        for body in ["[1, 2]", "\"ad.loaded\"", "42", "not json", "", "{\"adId\": \"ad-1\", \"type\": "] {
            page.receive(body, from: main)
        }
        let padding = String(repeating: "x", count: FrameMessage.maxMessageBytes)
        page.receive(json("ad.loaded", ["padding": padding]), from: main)
        #expect(page.state == .loading && recorder.events.isEmpty)
        page.receive(json("ad.loaded", ["padding": String(padding.prefix(1000))]), from: main)
        #expect(page.state == .loaded, "within the bound it parses")
    }

    @Test func messagesWithAnotherAdIdAreDropped() {
        let (page, recorder) = makePage()
        page.receive(message("ad.loaded", adId: "ad-2"), from: main)
        #expect(page.state == .loading)
        #expect(recorder.events.isEmpty)
    }

    @Test func malformedBodiesAreDropped() {
        let (page, recorder) = makePage()
        page.receive("ad.loaded", from: main)
        page.receive(["adId": "ad-1"], from: main)
        page.receive(["type": "ad.loaded"], from: main)
        #expect(recorder.events.isEmpty)
    }

    @Test func messagesFromASubframeAreDropped() {
        let (page, recorder) = makePage()
        page.receive(message("ad.loaded"), from: FrameProtocol.Sender(isMainFrame: false, scheme: "https", host: "server.kontext.so", port: 0))
        #expect(recorder.events.isEmpty)
    }

    @Test func messagesFromAnotherOriginAreDropped() {
        let (page, recorder) = makePage()
        page.receive(message("ad.loaded"), from: FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "evil.test", port: 0))
        page.receive(message("ad.loaded"), from: FrameProtocol.Sender(isMainFrame: true, scheme: "http", host: "server.kontext.so", port: 0))
        #expect(recorder.events.isEmpty)
    }

    @Test func originCheckTreatsPortZeroAsTheDefaultPort() {
        let (https, _) = makePage()
        #expect(https.frameProtocol.isFrameOrigin(FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 0)))
        #expect(https.frameProtocol.isFrameOrigin(FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 443)))
        #expect(!https.frameProtocol.isFrameOrigin(FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 8443)))

        let (local, _) = makePage(url: URL(string: "http://localhost:5175/frame/ad-1")!)
        #expect(local.frameProtocol.isFrameOrigin(FrameProtocol.Sender(isMainFrame: true, scheme: "http", host: "localhost", port: 5175)))
        #expect(!local.frameProtocol.isFrameOrigin(FrameProtocol.Sender(isMainFrame: true, scheme: "http", host: "localhost", port: 0)))

        let (custom, _) = makePage(url: URL(string: "kontext-test://frames/frame/ad-1")!)
        #expect(custom.frameProtocol.isFrameOrigin(FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)))
    }

    @Test func unknownTypesAreDropped() {
        let (page, recorder) = makePage()
        shown(page)
        page.receive(message("ad.whatever"), from: main)
        #expect(recorder.events.count == 1)
    }

    @Test func loadedIsAcceptedOnlyWhileLoading() {
        let (page, recorder) = makePage()
        page.receive(message("ad.loaded"), from: main)
        page.receive(message("ad.loaded"), from: main)
        #expect(recorder.events.count == 1)
    }

    @Test func showRequiresLoaded() {
        let (page, _) = makePage()
        page.show()
        #expect(page.state == .loading, "show before loaded is ignored")
        page.receive(message("ad.loaded"), from: main)
        page.show()
        #expect(page.state == .shown)
    }

    @Test func videoEventsRequireShown() {
        let (page, recorder) = makePage(isVideo: true)
        page.receive(message("ad.loaded"), from: main)
        page.receive(message("video.start", ["playhead": 0]), from: main)
        page.receive(message("video.complete", ["playhead": 10_000]), from: main)
        page.receive(message("ad.close", ["reason": "close"]), from: main)
        page.receive(message("video.skip", ["playhead": 1000]), from: main)
        #expect(recorder.events.count == 1, "only loaded; the rest came before show")
        #expect(page.state == .loaded)
    }

    @Test func aNonsensePlayheadFromThePageIsClamped() {
        let (page, recorder) = makePage(isVideo: true)
        shown(page)
        page.receive(message("video.start", ["playhead": 9_223_372_036_854_775_807]), from: main)
        guard case .video(_, let huge) = recorder.last else { Issue.record("expected video"); return }
        #expect(huge == 86_400_000, "a day at most")
        page.receive(message("video.pause", ["playhead": -7]), from: main)
        guard case .video(_, let negative) = recorder.last else { Issue.record("expected video"); return }
        #expect(negative == 0)
        page.receive(message("video.resume", ["playhead": 1e300]), from: main)
        guard case .video(_, let double) = recorder.last else { Issue.record("expected video"); return }
        #expect(double == 86_400_000, "a Double beyond Int saturates, then clamps")
    }

    @Test func videoEventsCarryTheirNameAndPlayhead() {
        let (page, recorder) = makePage(isVideo: true)
        shown(page)
        for event in FrameEvent.VideoEvent.allCases {
            page.receive(message("video.\(event.rawValue)", ["playhead": 1234]), from: main)
            guard case .video(let got, let playhead) = recorder.last else { Issue.record("expected video for \(event)"); continue }
            #expect(got == event)
            #expect(playhead == 1234)
        }
        let before = recorder.events.count
        page.receive(message("video.buffering", ["playhead": 1234]), from: main)
        #expect(recorder.events.count == before, "a video moment the SDK does not know is ignored")
    }

    @Test func progressCarriesTheOffset() {
        let (page, recorder) = makePage(isVideo: true)
        started(page)
        page.receive(message("video.progress", ["offset": 5000, "playhead": 5010]), from: main)
        guard case .progress(let offset, let playhead) = recorder.last else { Issue.record("expected progress"); return }
        #expect(offset == 5000)
        #expect(playhead == 5010)
        page.receive(message("video.progress", ["playhead": 5010]), from: main)
        #expect(recorder.events.count == 3, "loaded, start and one progress; the one without an offset is dropped")
    }

    @Test func completeDoesNotEndThePage() {
        let (page, recorder) = makePage(isVideo: true)
        started(page)
        page.receive(message("video.complete", ["playhead": 10_000]), from: main)
        guard case .complete(let playhead) = recorder.last else { Issue.record("expected complete"); return }
        #expect(playhead == 10_000)
        #expect(page.state == .shown, "the end card may follow")
    }

    @Test func closeWithoutAReasonOrWithAnUnknownOneReadsAsClose() {
        let (page, recorder) = makePage()
        shown(page)
        page.receive(message("ad.close"), from: main)
        guard case .close(let reason) = recorder.last else { Issue.record("expected close"); return }
        #expect(reason == .close)
        let (other, otherRecorder) = makePage()
        shown(other)
        other.receive(message("ad.close", ["reason": "swipe"]), from: main)
        guard case .close(let unknown) = otherRecorder.last else { Issue.record("expected close"); return }
        #expect(unknown == .close, "a reason the SDK does not know is a plain close")
    }

    @Test func skipEndsThePage() {
        let (page, recorder) = makePage(isVideo: true)
        shown(page)
        page.receive(message("video.skip", ["playhead": 4321]), from: main)
        guard case .skip(let playhead) = recorder.last else { Issue.record("expected skip"); return }
        #expect(playhead == 4321)
        #expect(page.state == .ended)
    }

    @Test func errorBeforeLoadedUsesTheLoadCodeWhenThePageGivesNone() {
        let (image, imageRecorder) = makePage(isVideo: false)
        image.receive(message("ad.error"), from: main)
        guard case .error(let code) = imageRecorder.last else { Issue.record("expected error"); return }
        #expect(code == 500, "NonLinear general code")
        #expect(image.state == .ended)

        let (video, videoRecorder) = makePage(isVideo: true)
        video.receive(message("ad.error"), from: main)
        guard case .error(let videoCode) = videoRecorder.last else { Issue.record("expected error"); return }
        #expect(videoCode == 400, "Linear general code")
    }

    @Test func errorAfterShowDefaultsTo405AndKeepsThePagesCode() {
        let (page, recorder) = makePage(isVideo: true)
        shown(page)
        page.receive(message("ad.error"), from: main)
        guard case .error(let code) = recorder.last else { Issue.record("expected error"); return }
        #expect(code == 405)

        let (other, otherRecorder) = makePage(isVideo: true)
        shown(other)
        other.receive(message("ad.error", ["code": 403]), from: main)
        guard case .error(let given) = otherRecorder.last else { Issue.record("expected error"); return }
        #expect(given == 403)
    }

    @Test func videoMessagesBeforeStartAreDropped() {
        let (page, recorder) = makePage(isVideo: true)
        shown(page)
        for type in ["video.progress", "video.firstQuartile", "video.midpoint", "video.thirdQuartile", "video.pause", "video.resume", "video.complete"] {
            page.receive(message(type, ["offset": 1000, "playhead": 5000]), from: main)
        }
        #expect(recorder.events.count == 1, "only ad.loaded: nothing before video.start")
        page.receive(message("video.mute"), from: main)
        page.receive(message("video.unmute"), from: main)
        #expect(recorder.events.count == 3, "mute and unmute are the viewer's, before start too")
        page.receive(message("video.start"), from: main)
        page.receive(message("video.firstQuartile", ["playhead": 4000]), from: main)
        page.receive(message("video.complete", ["playhead": 15000]), from: main)
        #expect(recorder.events.count == 6, "after start everything goes")
        guard case .complete = recorder.last else { Issue.record("expected complete"); return }
    }

    @Test func skipBeforeStartStillEndsTheAd() {
        let (page, recorder) = makePage(isVideo: true)
        shown(page)
        page.receive(message("video.skip"), from: main)
        guard case .skip = recorder.last else { Issue.record("expected skip"); return }
        #expect(page.state == .ended)
    }

    @Test func thePlayheadIsCappedAtTheVideosDurationAndTheGrace() {
        let (page, recorder) = makePage(isVideo: true, videoDuration: 15)
        shown(page)
        page.receive(message("video.start", ["playhead": 600_000]), from: main)
        guard case .video(_, let playhead) = recorder.last else { Issue.record("expected start"); return }
        #expect(playhead == 15000 + FrameProtocol.playheadGraceMs)
        page.receive(message("video.progress", ["offset": 600_000, "playhead": 600_000]), from: main)
        guard case .progress(let offset, let progressPlayhead) = recorder.last else { Issue.record("expected progress"); return }
        #expect(offset == 16000)
        #expect(progressPlayhead == 16000)
        page.receive(message("video.midpoint", ["playhead": 7500]), from: main)
        guard case .video(_, let within) = recorder.last else { Issue.record("expected midpoint"); return }
        #expect(within == 7500, "a playhead within the video is kept")
    }

    @Test func withoutADurationThePlayheadIsCappedAtADay() {
        let (page, recorder) = makePage(isVideo: true)
        shown(page)
        page.receive(message("video.start", ["playhead": 1e12]), from: main)
        guard case .video(_, let playhead) = recorder.last else { Issue.record("expected start"); return }
        #expect(playhead == 86_400_000)
    }

    @Test func aPageCodeOutsideTheVASTRangeGoesAs900() {
        for (sent, expected) in [(0, 900), (-1, 900), (42, 900), (99, 900), (100, 100), (999, 999), (1000, 900), (Int(Int32.max), 900)] {
            let (page, recorder) = makePage(isVideo: true)
            shown(page)
            page.receive(message("ad.error", ["code": sent]), from: main)
            guard case .error(let code) = recorder.last else { Issue.record("expected error for \(sent)"); return }
            #expect(code == expected, "code \(sent)")
        }
        let (huge, hugeRecorder) = makePage(isVideo: true)
        shown(huge)
        huge.receive(message("ad.error", ["code": 1e300]), from: main)
        guard case .error(let hugeCode) = hugeRecorder.last else { Issue.record("expected error"); return }
        #expect(hugeCode == 900)
    }

    @Test func clickNeedsAShownPageAndARecentTouch() {
        let (page, recorder) = makePage()
        page.receive(message("ad.loaded"), from: main)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "https://brand.test", "area": "creative"]), from: main)
        #expect(recorder.events.count == 1, "not shown yet")
        page.show()
        page.receive(message("ad.click", ["url": "https://brand.test", "area": "creative"]), from: main)
        guard case .click(let url, let fallback, let area) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.absoluteString == "https://brand.test")
        #expect(fallback == nil)
        #expect(area == .creative)
    }

    @Test func clickWithoutATouchIsDropped() {
        let (page, recorder) = makePage()
        shown(page)
        page.receive(message("ad.click", ["url": "https://brand.test"]), from: main)
        #expect(recorder.events.count == 1, "a click the viewer did not make is a forced redirect")
    }

    @Test func aClickWithoutAUsableURLOpensItsFallback() {
        let (page, recorder) = makePage()
        shown(page)
        // Missing, not a string, a space in it, a web link without a host: the same rule as on Android.
        for given: Any? in [nil, 42, "https://brand.test/a b", "https://", "https:///offer"] {
            page.noteTouch()
            var body: [String: Any] = ["fallbackUrl": "https://brand.test/offer"]
            body["url"] = given
            page.receive(message("ad.click", body), from: main)
            guard case .click(let url, let fallback, _) = recorder.last else { Issue.record("expected click for \(String(describing: given))"); return }
            #expect(url.absoluteString == "https://brand.test/offer" && fallback == nil)
            recorder.events.removeAll()
        }
    }

    @Test func clickKeepsTheFallbackAndDefaultsTheArea() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "brandapp://offer", "fallbackUrl": "https://brand.test/offer"]), from: main)
        guard case .click(let url, let fallback, let area) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.scheme == "brandapp", "deep links are allowed")
        #expect(fallback?.host == "brand.test")
        #expect(area == .creative)
    }

    @Test func aDeepLinkIntoTheHostAppOpens() {
        // Which links an ad may carry is the ad server's decision; the SDK opens the host app's own too.
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "hostapp://premium"]), from: main)
        guard case .click(let url, _, _) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.absoluteString == "hostapp://premium")
    }

    @Test func systemSchemesThatActWithoutAPageAreRefused() {
        // The driver's clock stands still: every touch below is fresh however slow the runner.
        let (page, recorder) = makePage()
        shown(page)
        let refused = ["tel:+15555550100", "telprompt:+15555550100", "sms:+15555550100&body=hi", "mms:+15555550100",
                       "facetime:+15555550100", "facetime-audio:+15555550100",
                       "itms-services://?action=download-manifest&url=https://evil.test/app.plist",
                       "shortcuts://run-shortcut?name=x", "app-settings:", "prefs:root=General", "App-Prefs:root=General"]
        for raw in refused {
            page.noteTouch()
            page.receive(message("ad.click", ["url": raw]), from: main)
            page.receive(message("ad.open", ["url": raw, "purpose": "adChoices"]), from: main)
            page.externalNavigation(to: URL(string: raw)!)
            page.receive(message("ad.click", ["url": "https://brand.test", "fallbackUrl": raw]), from: main)
            guard case .click(let url, let fallback, _) = recorder.last else { Issue.record("expected the web click for \(raw)"); continue }
            #expect(url.scheme == "https", "\(raw) opened nothing, the touch was left for the web click")
            #expect(fallback == nil, "\(raw) refused as a fallback")
        }
        #expect(recorder.events.count == 1 + refused.count, "only the web clicks: \(recorder.events)")
    }

    @Test func aRefusedURLWithAnAllowedFallbackOpensTheFallback() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "itms-services://?action=download-manifest", "fallbackUrl": "http://brand.test/offer"]), from: main)
        guard case .click(let url, let fallback, _) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.absoluteString == "http://brand.test/offer" && fallback == nil)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "tel:+15555550100", "fallbackUrl": "sms:+15555550100"]), from: main)
        #expect(recorder.events.count == 2, "both refused: nothing opens")
    }

    @Test func intentSchemeIsRefused() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "intent://scan/#Intent;scheme=zxing;end"]), from: main)
        page.receive(message("ad.open", ["url": "INTENT://x", "purpose": "adChoices"]), from: main)
        #expect(recorder.events.count == 1)
    }

    @Test func aRefusedFallbackIsDroppedAndTheClickStays() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "https://brand.test/offer", "fallbackUrl": "intent://x"]), from: main)
        guard case .click(let url, let fallback, _) = recorder.last else { Issue.record("expected click"); return }
        #expect(url.host == "brand.test" && fallback == nil, "the fallback is opened under the same policy as the URL")
    }

    @Test func schemesThatAreNotLinksAreRefused() {
        let (page, recorder) = makePage()
        shown(page)
        for raw in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "blob:https://x/y", "about:blank"] {
            page.noteTouch()
            page.receive(message("ad.click", ["url": raw]), from: main)
        }
        #expect(recorder.events.count == 1, "\(recorder.events)")
        page.noteTouch()
        page.receive(message("ad.click", ["url": "itms-apps://apps.apple.com/app/id1"]), from: main)
        #expect(recorder.events.count == 2, "store links open")
    }

    @Test func oneTouchOpensOneURL() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.click", ["url": "https://brand.test/offer"]), from: main)
        page.externalNavigation(to: URL(string: "https://brand.test/offer")!)
        page.receive(message("ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"]), from: main)
        #expect(recorder.events.count == 2, "the tap was spent by the click: \(recorder.events)")
        page.noteTouch()
        page.externalNavigation(to: URL(string: "https://brand.test/other")!)
        #expect(recorder.events.count == 3, "a new tap opens again")
    }

    @Test func aRedirectWithTheExplicitDefaultPortIsTheSameOrigin() {
        let (https, _) = makePage(url: URL(string: "https://server.kontext.so/frame/ad-1")!)
        #expect(https.frameProtocol.isSameOrigin(URL(string: "https://server.kontext.so:443/frame/ad-1/next")!))
        #expect(https.frameProtocol.isSameOrigin(URL(string: "https://server.kontext.so/other")!))
        #expect(!https.frameProtocol.isSameOrigin(URL(string: "https://server.kontext.so:8443/frame/ad-1")!))
        #expect(!https.frameProtocol.isSameOrigin(URL(string: "http://server.kontext.so/frame/ad-1")!))
        #expect(!https.frameProtocol.isSameOrigin(URL(string: "https://evil.test/frame/ad-1")!))
        let (local, _) = makePage(url: URL(string: "http://localhost:5175/frame/ad-1")!)
        #expect(local.frameProtocol.isSameOrigin(URL(string: "http://localhost:5175/x")!))
        #expect(!local.frameProtocol.isSameOrigin(URL(string: "http://localhost/x")!))
    }

    @Test func aTouchTooLongAgoAuthorizesNothing() {
        let (page, recorder) = makePage()
        shown(page)
        let before = recorder.events.count
        page.noteTouch()
        page.now += TouchGate.window + 0.5
        page.receive(message("ad.click", ["url": "https://brand.test"]), from: main)
        page.externalNavigation(to: URL(string: "https://brand.test")!)
        #expect(recorder.events.count == before, "an expired touch opens nothing")
        page.noteTouch()
        page.now += TouchGate.window - 0.1
        page.receive(message("ad.click", ["url": "https://brand.test"]), from: main)
        #expect(recorder.events.count == before + 1, "a touch within the window still does")
    }

    @Test func aFractionalOffsetOrPlayheadIsRoundedToTheNearestMillisecond() {
        let (page, recorder) = makePage(isVideo: true)
        started(page)
        page.receive(message("video.progress", ["offset": 4957.59, "playhead": 5010.4]), from: main)
        guard case .progress(let offset, let playhead)? = recorder.last else { Issue.record("expected progress"); return }
        #expect(offset == 4958 && playhead == 5010)
        page.receive(message("video.skip", ["playhead": 1234.5]), from: main)
        guard case .skip(let skipped)? = recorder.last else { Issue.record("expected skip"); return }
        #expect(skipped == 1235)
    }

    @Test func aMalformedProgressOffsetIsDropped() {
        let (page, recorder) = makePage(isVideo: true)
        started(page)
        let before = recorder.events.count
        for offset in [1e300, -5, Double.infinity, 86_400_001] as [Double] {
            page.receive(message("video.progress", ["offset": offset, "playhead": 0]), from: main)
        }
        page.receive(message("video.progress", ["offset": "5000", "playhead": 0]), from: main)
        #expect(recorder.events.count == before, "no progress event from a malformed offset")
        page.receive(message("video.progress", ["offset": 5000, "playhead": 5000]), from: main)
        guard case .progress(let offset, _)? = recorder.last else { Issue.record("expected progress"); return }
        #expect(offset == 5000, "a valid checkpoint still works")
    }

    @Test func originsCompareWithoutCase() {
        let (page, _) = makePage(url: URL(string: "HTTPS://Server.Kontext.SO/frame/ad-1")!)
        #expect(page.frameProtocol.isFrameOrigin(main), "WebKit reports the canonical lowercase origin")
        #expect(page.frameProtocol.isSameOrigin(URL(string: "https://server.kontext.so:443/next")!))
        let (local, _) = makePage(url: URL(string: "HTTP://LOCALHOST:5175/frame/ad-1")!)
        #expect(local.frameProtocol.isFrameOrigin(FrameProtocol.Sender(isMainFrame: true, scheme: "http", host: "localhost", port: 5175)))
        #expect(local.frameProtocol.isSameOrigin(URL(string: "http://localhost:5175/x")!))
        let (plain, _) = makePage(url: URL(string: "HTTP://LOCALHOST/frame/ad-1")!)
        #expect(plain.frameProtocol.isSameOrigin(URL(string: "http://localhost:80/x")!), "the default port, whatever the scheme's case")
        #expect(!page.frameProtocol.isSameOrigin(URL(string: "https://other.kontext.so/x")!) && !page.frameProtocol.isSameOrigin(URL(string: "http://server.kontext.so/x")!), "a different host or scheme is still another origin")
        #expect(!page.frameProtocol.isSameOrigin(URL(string: "https://server.kontext.so:8443/x")!), "and a different port")
    }

    @Test func navigationsBeforeAndAfterThePageIsReady() {
        let (page, _) = makePage()
        let pageURL = URL(string: "https://server.kontext.so/frame/ad-1")!
        let decide = { (target: String, mainFrame: Bool) in page.frameProtocol.navigationDecision(to: URL(string: target)!, isMainFrame: mainFrame, current: pageURL) }
        // Loading: its own origin (redirects) and about:blank go through; elsewhere is a click.
        #expect(decide("https://server.kontext.so/frame/ad-1/v2", true) == .allow)
        #expect(decide("about:blank", true) == .allow)
        #expect(decide("https://brand.test/", true) == .external)
        shown(page)
        // Ready: the document stays.
        #expect(decide("https://server.kontext.so/frame/ad-1#endcard", true) == .allow, "a fragment, within the document")
        #expect(decide("https://server.kontext.so/frame/ad-1", true) == .cancel, "the current URL without a fragment loads a new document")
        #expect(page.frameProtocol.navigationDecision(to: pageURL, isMainFrame: true, isReload: true, current: pageURL) == .cancel, "so does a reload")
        let anchored = URL(string: "https://server.kontext.so/frame/ad-1#endcard")!
        #expect(page.frameProtocol.navigationDecision(to: anchored, isMainFrame: true, isReload: true, current: anchored) == .cancel, "a reload, even with a fragment")
        #expect(page.frameProtocol.navigationDecision(to: anchored, isMainFrame: true, current: anchored) == .allow, "the same fragment again stays within the document")
        let submitted = URL(string: "https://server.kontext.so/frame/ad-1#submitted")!
        #expect(page.frameProtocol.navigationDecision(to: submitted, isMainFrame: true, isSubmission: true, current: pageURL) == .cancel,
                "a form POST to the current URL and a fragment loads a new document")
        #expect(page.frameProtocol.navigationDecision(to: URL(string: "https://brand.test/#x")!, isMainFrame: true, isSubmission: true, current: pageURL) == .external)
        #expect(decide("https://server.kontext.so/frame/other", true) == .cancel, "a same-origin page would replace the creative")
        #expect(decide("about:blank", true) == .cancel, "and so would a blank page")
        #expect(decide("https://brand.test/", true) == .external)
        #expect(decide("https://anything.test/creative", false) == .allow, "the creative's own iframe navigates freely")
    }

    @Test func openCarriesThePurposeAndIsNotAClick() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"]), from: main)
        guard case .open(let url, let purpose) = recorder.last else { Issue.record("expected open"); return }
        #expect(url.host == "adchoices.test")
        #expect(purpose == "adChoices")
    }

    @Test func anOpenWithoutAPurposeIsUnknownAndAnUnfamiliarOneIsKept() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.open", ["url": "https://privacy.test"]), from: main)
        guard case .open(_, let missing) = recorder.last else { Issue.record("expected open"); return }
        #expect(missing == "unknown")
        page.noteTouch()
        page.receive(message("ad.open", ["url": "https://privacy.test", "purpose": "whyThisAd"]), from: main)
        guard case .open(_, let unfamiliar) = recorder.last else { Issue.record("expected open"); return }
        #expect(unfamiliar == "whyThisAd", "passed through unchanged")
    }

    @Test func invalidURLsAreDropped() {
        let (page, recorder) = makePage()
        shown(page)
        page.noteTouch()
        page.receive(message("ad.click", ["url": 42]), from: main)
        page.receive(message("ad.click", ["url": ""]), from: main)
        #expect(recorder.events.count == 1)
    }
}
