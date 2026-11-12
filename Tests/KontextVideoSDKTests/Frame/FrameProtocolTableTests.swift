import Foundation
@testable import KontextVideoSDK
import Testing

/// `FrameProtocol` as tables over plain values, no WebView: every message in every state, the envelope and the
/// sender, the playhead's bounds, the order of the video's events, the violation reported once, the touch
/// window; the navigation decisions are FrameNavigationTests'.
@Suite
@MainActor
struct FrameProtocolTableTests {
    private static let page = URL(string: "https://server.kontext.so/frame/ad-1")!
    private let main = FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 0)

    enum Stage: CaseIterable {
        case loading, loaded, shown, ended
    }

    private func core(_ stage: Stage = .loading, videoDuration: TimeInterval? = nil, started: Bool = true) -> FrameProtocol {
        var core = FrameProtocol(bidId: "ad-1", pageURL: Self.page, isVideo: true, videoDuration: videoDuration)
        guard stage != .loading else { return core }
        _ = core.accept(message("ad.loaded"), from: main, now: 0)
        guard stage != .loaded else { return core }
        _ = core.show()
        if started { _ = core.accept(message("video.start"), from: main, now: 0) }
        if stage == .ended { _ = core.end() }
        return core
    }

    private func message(_ type: String, _ extra: [String: Any] = [:], bidId: String = "ad-1") -> [String: Any] {
        var body: [String: Any] = ["bidId": bidId, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        return body
    }

    private func kind(_ step: FrameProtocol.Step) -> String {
        switch step {
        case .ignore: "ignore"
        case .drop: "drop"
        case .loaded: "loaded"
        case .deliver: "deliver"
        case .endThenDeliver: "end"
        }
    }

    private func violation(_ step: FrameProtocol.Step) -> String? {
        if case .drop(_, _, let violation) = step { return violation }
        return nil
    }

    private func event(_ step: FrameProtocol.Step) -> FrameEvent? {
        switch step {
        case .deliver(let event), .endThenDeliver(let event): event
        case .ignore, .drop, .loaded: nil
        }
    }

    // MARK: Message × state

    @Test func everyMessageInEveryState() {
        // loading, loaded, shown (video started), ended
        let table: [(String, [String: Any], [String])] = [
            ("ad.loaded", [:], ["loaded", "ignore", "ignore", "ignore"]),
            ("ad.click", ["url": "https://brand.test"], ["ignore", "ignore", "deliver", "ignore"]),
            ("ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"], ["ignore", "ignore", "deliver", "ignore"]),
            ("ad.close", ["reason": "close"], ["ignore", "ignore", "end", "ignore"]),
            ("video.skip", ["playhead": 1000], ["ignore", "ignore", "end", "ignore"]),
            ("video.start", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.firstQuartile", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.midpoint", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.thirdQuartile", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.pause", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.resume", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.mute", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.unmute", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.progress", ["offset": 1000], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.complete", [:], ["ignore", "ignore", "deliver", "ignore"]),
            ("video.buffering", [:], ["drop", "drop", "drop", "ignore"]),   // an unknown video.* type, dropped with a line
            ("ad.error", ["code": 405], ["end", "end", "end", "ignore"]),
            ("ad.whatever", [:], ["drop", "drop", "drop", "ignore"]),
        ]
        for (type, extra, expected) in table {
            let row = Stage.allCases.map { stage -> String in
                var core = core(stage)
                core.noteTouch(now: 10)
                return kind(core.accept(message(type, extra), from: main, now: 10))
            }
            #expect(row == expected, "\(type): loading, loaded, shown, ended")
        }
    }

    @Test func loadedMovesTheStateAndShowNeedsIt() {
        var core = core()
        let holds1 = !core.show() && core.state == .loading
        #expect(holds1, "show before loaded is ignored")
        let holds2 = kind(core.accept(message("ad.loaded"), from: main, now: 0)) == "loaded" && core.state == .loaded
        #expect(holds2)
        let holds3 = core.show() && core.state == .shown
        #expect(holds3)
        let holds4 = core.end() && core.state == .ended
        #expect(holds4)
        let holds5 = !core.end()
        #expect(holds5, "once")
    }

    @Test func theErrorCodeOfEveryState() {
        // The page's code when it is a VAST one, 900 when it is not, the state's own when it gives none.
        for (stage, sent, expected) in [(Stage.loading, nil, 400), (.loaded, nil, 400), (.shown, nil, 405),
                                        (.shown, 403, 403), (.shown, 42, 900), (.loading, 1000, 900)] as [(Stage, Int?, Int)] {
            var core = core(stage)
            let step = core.accept(message("ad.error", sent.map { ["code": $0] } ?? [:]), from: main, now: 0)
            guard case .error(let code)? = event(step) else { Issue.record("expected an error in \(stage)"); continue }
            #expect(code == expected, "\(stage), code \(String(describing: sent))")
        }
        let image = FrameProtocol(bidId: "ad-1", pageURL: Self.page, isVideo: false, videoDuration: nil)
        #expect(image.loadErrorCode == 500 && image.failureCode == 500)
        #expect(core(.shown).failureCode == 405 && core(.loaded).failureCode == 400)
    }

    @Test func theErrorCodeForEveryKindOfValue() {
        // The VAST range is 100...999 inclusive; any other number is 900; a code that is no number is the state's own.
        let rows: [(Any, Int)] = [
            (100, 100), (999, 999), (99, 900), (1000, 900), (0, 900), (-0.0, 900), (-1, 900), (-400, 900), (42, 900),
            (Int(Int32.max), 900), (1e300, 900),
            (403.4, 403), (403.6, 403), ("403", 405), (true, 405), (NSNull(), 405), ([403], 405), (["code": 403], 405),
        ]
        for (sent, expected) in rows {
            var core = core(.shown)
            let step = core.accept(message("ad.error", ["code": sent]), from: main, now: 0)
            guard case .error(let code)? = event(step) else { Issue.record("expected an error for \(sent)"); continue }
            #expect(code == expected, "code \(sent)")
        }
        // As the page posts it, a JSON string: a number past a Double is no code the SDK can read.
        var core = core(.shown)
        let step = core.accept(#"{"adId":"ad-1","type":"ad.error","code":1e400}"#, from: main, now: 0)
        switch event(step) {
        case .error(let code)?: #expect(code == 900 || code == 405, "\(code)")
        case nil: #expect(kind(step) == "drop", "or the envelope is refused")
        default: Issue.record("unexpected \(step)")
        }
    }

    @Test func everyCloseReasonAndOnesTheSDKDoesNotKnow() {
        let rows: [(Any?, FrameEvent.CloseReason)] = [
            ("close", .close), ("resume", .resume), ("complete", .complete), (nil, .close), ("", .close),
            ("CLOSE", .close), ("Resume", .close), ("COMPLETE", .close), ("swipe", .close), (7, .close), (true, .close),
        ]
        for (sent, expected) in rows {
            var core = core(.shown)
            let step = core.accept(message("ad.close", sent.map { ["reason": $0] } ?? [:]), from: main, now: 0)
            guard case .close(let reason)? = event(step) else { Issue.record("expected a close for \(String(describing: sent))"); continue }
            #expect(reason == expected && kind(step) == "end", "\(String(describing: sent))")
        }
    }

    @Test func theProgressOffsetForEveryKindOfValue() {
        let day = FrameProtocol.dayMs
        // sent, the offset delivered or nil when dropped as a violation
        let rows: [(Any?, Int?)] = [
            (0, 0), (-0.0, 0), (0.4, 0), (4957.59, 4958), (day, day), (Double(day) + 0.4, nil), (day + 1, nil), (-0.4, nil), (-1, nil),
            (-5, nil), (1e300, nil), (Double.infinity, nil), (-Double.infinity, nil),
            (nil, nil), ("1000", nil), (true, nil), (NSNull(), nil), ([1000], nil), (["ms": 1000], nil),
        ]
        for (sent, expected) in rows {
            var core = core(.shown)
            let step = core.accept(message("video.progress", sent.map { ["offset": $0] } ?? [:]), from: main, now: 0)
            if let expected {
                guard case .progress(let offset, _)? = event(step) else { Issue.record("expected progress for \(String(describing: sent))"); continue }
                #expect(offset == expected, "\(String(describing: sent))")
            } else {
                #expect(violation(step) == "progress.offset", "\(String(describing: sent))")
            }
        }
    }

    @Test func aNegativeOrZeroVideoDurationBoundsThePlayheadAtTheGrace() {
        for duration in [-30.0, 0, -0.0] {
            let core = FrameProtocol(bidId: "ad-1", pageURL: Self.page, isVideo: true, videoDuration: duration)
            #expect(core.playheadLimitMs == FrameProtocol.playheadGraceMs, "\(duration)")
        }
        #expect(FrameProtocol(bidId: "ad-1", pageURL: Self.page, isVideo: true, videoDuration: 15.0004).playheadLimitMs == 16_000, "rounded")
        var core = core(.shown, videoDuration: -30)
        guard case .video(_, let playhead)? = event(core.accept(message("video.pause", ["playhead": 5000]), from: main, now: 0)) else {
            Issue.record("expected a video event"); return
        }
        #expect(playhead == FrameProtocol.playheadGraceMs)
    }

    @Test func anOpenTakesNoFallbackAndAClickWithNeitherURLIsIgnored() {
        var core = core(.shown)
        core.noteTouch(now: 1)
        let open = core.accept(message("ad.open", ["url": "tel:1", "fallbackUrl": "https://brand.test"]), from: main, now: 1)
        #expect(kind(open) == "drop", "an open's refused URL is not saved by a fallback")
        let neither = core.accept(message("ad.click", ["url": "", "fallbackUrl": 5]), from: main, now: 1)
        #expect(kind(neither) == "ignore")
        let fallbackOnly = core.accept(message("ad.click", ["fallbackUrl": "https://brand.test/f"]), from: main, now: 1)
        guard case .click(let url, let fallback, let area)? = event(fallbackOnly) else { Issue.record("expected the fallback"); return }
        #expect(url.absoluteString == "https://brand.test/f" && fallback == nil && area == .creative, "the touch was still there for it")
    }

    @Test func theClickAreaForEveryValue() {
        let rows: [(Any?, VideoAd.Click.Area)] = [
            (nil, .creative), ("creative", .creative), ("endCard", .endCard), ("cta", .other("cta")), ("", .other("")),
            ("EndCard", .other("EndCard")), (7, .creative), (NSNull(), .creative),
        ]
        for (sent, expected) in rows {
            var core = core(.shown)
            core.noteTouch(now: 1)
            var extra: [String: Any] = ["url": "https://brand.test"]
            extra["area"] = sent
            guard case .click(_, _, let area)? = event(core.accept(message("ad.click", extra), from: main, now: 1)) else {
                Issue.record("expected a click for \(String(describing: sent))"); continue
            }
            #expect(area == expected, "\(String(describing: sent))")
        }
    }

    // MARK: Envelope and sender

    @Test func theEnvelopeAndTheSender() {
        let senders: [(FrameProtocol.Sender, Bool)] = [
            (main, true),
            (.init(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 443), true),
            (.init(isMainFrame: true, scheme: "https", host: "SERVER.kontext.so", port: 0), true),
            (.init(isMainFrame: false, scheme: "https", host: "server.kontext.so", port: 0), false),
            (.init(isMainFrame: true, scheme: "https", host: "evil.test", port: 0), false),
            (.init(isMainFrame: true, scheme: "http", host: "server.kontext.so", port: 0), false),
            (.init(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 8443), false),
        ]
        for (sender, accepted) in senders {
            var core = core()
            let holds6 = kind(core.accept(message("ad.loaded"), from: sender, now: 0)) == (accepted ? "loaded" : "drop")
            #expect(holds6, "\(sender)")
        }
        // A message of exactly `maxMessageBytes` bytes parses; one byte more is dropped.
        let head = "{\"bidId\":\"ad-1\",\"type\":\"ad.loaded\",\"padding\":\"", tail = "\"}"
        let atLimit = head + String(repeating: "x", count: FrameMessage.maxMessageBytes - head.utf8.count - tail.utf8.count) + tail
        #expect(FrameMessage.maxMessageBytes == 1024 * 1024 && atLimit.utf8.count == FrameMessage.maxMessageBytes)
        let bodies: [(Any, String)] = [
            (message("ad.loaded", bidId: "ad-2"), "drop"),
            (["bidId": "ad-1"], "drop"),
            ("not json", "drop"),
            ("[1, 2]", "drop"),
            (head + "x" + atLimit.dropFirst(head.utf8.count), "drop"),
            (atLimit, "loaded"),
            ("{\"bidId\":\"ad-1\",\"type\":\"ad.loaded\"}", "loaded"),
        ]
        for (body, expected) in bodies {
            var core = core()
            let holds7 = kind(core.accept(body, from: main, now: 0)) == expected
            #expect(holds7, "\(String(describing: body).prefix(60))")
        }
    }

    @Test func aViolationIsReportedOnce() {
        var core = core(.shown, started: false)
        let holds8 = violation(core.accept(message("video.firstQuartile"), from: main, now: 0)) == "video.beforeStart"
        #expect(holds8)
        let holds9 = violation(core.accept(message("video.firstQuartile"), from: main, now: 0)) == nil
        #expect(holds9)
        let holds10 = violation(core.accept("broken", from: main, now: 0)) == nil
        #expect(holds10, "one fault per ad, whatever it is")
        var other = self.core()
        let holds11 = violation(other.accept("broken", from: main, now: 0)) == "envelope"
        #expect(holds11)
        var progress = self.core(.shown)
        let holds12 = violation(progress.accept(message("video.progress", ["offset": -5]), from: main, now: 0)) == "progress.offset"
        #expect(holds12)
        let holds13 = violation(progress.accept(message("ad.whatever"), from: main, now: 0)) == nil
        #expect(holds13, "an unknown type is no violation")
        for state in [Stage.loading, .loaded, .shown] {
            var unknownVideo = self.core(state)
            guard case .drop(_, _, nil) = unknownVideo.accept(message("video.foo"), from: main, now: 0) else {
                Issue.record("video.foo in \(state): dropped with a line, no violation"); continue
            }
        }
    }

    // MARK: Playhead and order

    @Test func thePlayheadIsClamped() {
        // sent, video duration, expected
        let rows: [(Double, TimeInterval?, Int)] = [
            (1234.5, nil, 1235), (-7, nil, 0), (1e300, nil, 86_400_000), (.infinity, nil, 0),
            (600_000, 15, 16_000), (7500, 15, 7500),
        ]
        for (sent, duration, expected) in rows {
            var core = core(.shown, videoDuration: duration)
            guard case .video(_, let playhead)? = event(core.accept(message("video.pause", ["playhead": sent]), from: main, now: 0)) else {
                Issue.record("expected a video event for \(sent)"); continue
            }
            #expect(playhead == expected, "\(sent), duration \(String(describing: duration))")
        }
        var core = core(.shown, videoDuration: 15)
        guard case .progress(let offset, _)? = event(core.accept(message("video.progress", ["offset": 600_000]), from: main, now: 0)) else {
            Issue.record("expected progress"); return
        }
        #expect(offset == 16_000, "the offset is capped like the playhead")
    }

    @Test func theVideosEventsWaitForItsStart() {
        var core = core(.shown, started: false)
        for type in ["video.progress", "video.firstQuartile", "video.midpoint", "video.thirdQuartile", "video.pause", "video.resume", "video.complete"] {
            let holds14 = kind(core.accept(message(type, ["offset": 1000]), from: main, now: 0)) == "drop"
            #expect(holds14, "\(type)")
        }
        let holds15 = kind(core.accept(message("video.mute"), from: main, now: 0)) == "deliver"
        #expect(holds15, "the viewer's, before start too")
        let holds16 = kind(core.accept(message("video.skip"), from: main, now: 0)) == "end"
        #expect(holds16, "a skip needs no start")
        var started = self.core(.shown, started: false)
        let holds17 = kind(started.accept(message("video.start"), from: main, now: 0)) == "deliver"
        #expect(holds17)
        let holds18 = kind(started.accept(message("video.complete"), from: main, now: 0)) == "deliver"
        #expect(holds18)
    }

    @Test func afterTheVideoCompletedOnlyMuteAndUnmuteCount() {
        var core = core(.shown)
        #expect(kind(core.accept(message("video.complete"), from: main, now: 0)) == "deliver")
        for type in ["video.resume", "video.start", "video.pause", "video.firstQuartile", "video.complete"] {
            let holds = kind(core.accept(message(type), from: main, now: 0)) == "ignore"
            #expect(holds, "\(type) after video.complete")
        }
        let holds1 = kind(core.accept(message("video.progress", ["offset": 1000]), from: main, now: 0)) == "ignore"
        #expect(holds1, "progress after video.complete")
        let holds2 = kind(core.accept(message("video.mute"), from: main, now: 0)) == "deliver"
            && kind(core.accept(message("video.unmute"), from: main, now: 0)) == "deliver"
        #expect(holds2, "the viewer's mute and unmute still count")
        let holds3 = kind(core.accept(message("video.skip"), from: main, now: 0)) == "end"
        #expect(holds3, "the page may still end")
    }

    @Test func aVideoLongerThanADayHasItsProgressPastADay() {
        let day = 86_400_000
        var long = core(.shown, videoDuration: 2 * 86_400)
        let step = long.accept(message("video.progress", ["offset": day + day / 2, "playhead": day + day / 2]), from: main, now: 0)
        guard case .progress(let offset, let playhead)? = event(step) else { Issue.record("expected progress"); return }
        #expect(offset == day + day / 2 && playhead == day + day / 2)
        var unknown = core(.shown)
        let holds = violation(unknown.accept(message("video.progress", ["offset": day + 1]), from: main, now: 0)) == "progress.offset"
        #expect(holds, "without a duration, a day is the bound")
    }

    // MARK: Touches and navigation

    @Test func oneTouchOpensOneURLWithinTheWindow() {
        let click = message("ad.click", ["url": "https://brand.test"])
        var core = core(.shown)
        let holds19 = kind(core.accept(click, from: main, now: 100)) == "drop"
        #expect(holds19, "no touch")
        core.noteTouch(now: 100)
        let holds20 = kind(core.accept(click, from: main, now: 100 + TouchGate.window)) == "deliver"
        #expect(holds20, "at the window's edge")
        let holds21 = kind(core.accept(click, from: main, now: 101)) == "drop"
        #expect(holds21, "the touch was spent")
        core.noteTouch(now: 200)
        let holds22 = core.externalNavigation(to: URL(string: "https://brand.test")!, now: 202) == nil
        #expect(holds22, "too long ago")
        core.noteTouch(now: 300)
        let holds23 = core.externalNavigation(to: URL(string: "tel:+15555550100")!, now: 300) == nil
        #expect(holds23, "a refused scheme")
        let holds24 = core.externalNavigation(to: URL(string: "https://brand.test")!, now: 300) != nil
        #expect(holds24, "the touch was left for this")
        core.noteTouch(now: 400)
        let holds25 = kind(core.accept(message("ad.click", ["url": "tel:+15555550100"]), from: main, now: 400)) == "drop"
        #expect(holds25)
        guard case .click(let url, let fallback, _)? = event(core.accept(message("ad.click", ["url": "tel:1", "fallbackUrl": "https://brand.test/offer"]), from: main, now: 400)) else {
            Issue.record("expected the fallback"); return
        }
        #expect(url.absoluteString == "https://brand.test/offer" && fallback == nil)
    }
}
