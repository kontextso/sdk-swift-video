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
        var core = FrameProtocol(adId: "ad-1", pageURL: Self.page, isVideo: true, videoDuration: videoDuration)
        guard stage != .loading else { return core }
        _ = core.accept(message("ad.loaded"), from: main, now: 0)
        guard stage != .loaded else { return core }
        _ = core.show()
        if started { _ = core.accept(message("video.start"), from: main, now: 0) }
        if stage == .ended { _ = core.end() }
        return core
    }

    private func message(_ type: String, _ extra: [String: Any] = [:], adId: String = "ad-1") -> [String: Any] {
        var body: [String: Any] = ["adId": adId, "type": type]
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
        let image = FrameProtocol(adId: "ad-1", pageURL: Self.page, isVideo: false, videoDuration: nil)
        #expect(image.loadErrorCode == 500 && image.failureCode == 500)
        #expect(core(.shown).failureCode == 405 && core(.loaded).failureCode == 400)
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
        let head = "{\"adId\":\"ad-1\",\"type\":\"ad.loaded\",\"padding\":\"", tail = "\"}"
        let atLimit = head + String(repeating: "x", count: FrameMessage.maxMessageBytes - head.utf8.count - tail.utf8.count) + tail
        #expect(FrameMessage.maxMessageBytes == 1024 * 1024 && atLimit.utf8.count == FrameMessage.maxMessageBytes)
        let bodies: [(Any, String)] = [
            (message("ad.loaded", adId: "ad-2"), "drop"),
            (["adId": "ad-1"], "drop"),
            ("not json", "drop"),
            ("[1, 2]", "drop"),
            (head + "x" + atLimit.dropFirst(head.utf8.count), "drop"),
            (atLimit, "loaded"),
            ("{\"adId\":\"ad-1\",\"type\":\"ad.loaded\"}", "loaded"),
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
