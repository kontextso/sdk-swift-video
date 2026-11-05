import Foundation
@testable import KontextVideoSDK
import Testing

/// Every message type of the Kontext Frame Protocol in every state of the bridge, as one table: what reaches
/// the ad. A characterization of the bridge as a whole (envelope, sender, state, order, touch), so a change
/// to any of its rules shows up here as a changed cell.
///
/// ```
///   outcome   what the ad gets
///   loaded    `.loaded`; the bridge moves to loaded
///   deliver   the event; the bridge stays where it was
///   end       the event, after the bridge ended (close, skip, error)
///   drop      nothing
/// ```
extension SerialSuites {
@Suite
@MainActor
struct FrameMessageTableTests {
    private let main = FrameProtocol.Sender(isMainFrame: true, scheme: "https", host: "server.kontext.so", port: 0)

    init() { SDKHarness.reset() }

    enum Outcome: Equatable {
        case loaded, deliver, end, drop
    }

    enum Stage: CaseIterable {
        case loading, loaded, shown, ended
    }

    /// Each message with a payload that passes every check but the state's: a usable URL, a touch before it,
    /// a valid offset and code.
    private static let messages: [(type: String, body: [String: Any])] = [
        ("ad.loaded", [:]),
        ("ad.click", ["url": "https://brand.test/offer"]),
        ("ad.open", ["url": "https://adchoices.test", "purpose": "adChoices"]),
        ("ad.close", ["reason": "close"]),
        ("video.skip", ["playhead": 1000]),
        ("video.start", ["playhead": 0]),
        ("video.firstQuartile", ["playhead": 1000]),
        ("video.midpoint", ["playhead": 1000]),
        ("video.thirdQuartile", ["playhead": 1000]),
        ("video.pause", ["playhead": 1000]),
        ("video.resume", ["playhead": 1000]),
        ("video.mute", ["playhead": 1000]),
        ("video.unmute", ["playhead": 1000]),
        ("video.progress", ["offset": 1000, "playhead": 1000]),
        ("video.complete", ["playhead": 1000]),
        ("video.buffering", ["playhead": 1000]),
        ("ad.error", ["code": 405]),
        ("ad.whatever", [:]),
    ]

    /// Columns: loading, loaded, shown (with `video.start` received), ended.
    private static let expected: [String: [Outcome]] = [
        "ad.loaded": [.loaded, .drop, .drop, .drop],
        "ad.click": [.drop, .drop, .deliver, .drop],
        "ad.open": [.drop, .drop, .deliver, .drop],
        "ad.close": [.drop, .drop, .end, .drop],
        "video.skip": [.drop, .drop, .end, .drop],
        "video.start": [.drop, .drop, .deliver, .drop],
        "video.firstQuartile": [.drop, .drop, .deliver, .drop],
        "video.midpoint": [.drop, .drop, .deliver, .drop],
        "video.thirdQuartile": [.drop, .drop, .deliver, .drop],
        "video.pause": [.drop, .drop, .deliver, .drop],
        "video.resume": [.drop, .drop, .deliver, .drop],
        "video.mute": [.drop, .drop, .deliver, .drop],
        "video.unmute": [.drop, .drop, .deliver, .drop],
        "video.progress": [.drop, .drop, .deliver, .drop],
        "video.complete": [.drop, .drop, .deliver, .drop],
        "video.buffering": [.drop, .drop, .drop, .drop],
        "ad.error": [.end, .end, .end, .drop],
        "ad.whatever": [.drop, .drop, .drop, .drop],
    ]

    private func bridge(in stage: Stage) -> (FrameBridge, () -> [FrameEvent]) {
        let bridge = FrameBridge(adId: "ad-1", url: URL(string: "https://server.kontext.so/frame/ad-1")!, isVideo: true)
        var events: [FrameEvent] = []
        bridge.onEvent = { events.append($0) }
        switch stage {
        case .loading:
            break
        case .loaded:
            bridge.receive(["adId": "ad-1", "type": "ad.loaded"], from: main)
        case .shown:
            bridge.receive(["adId": "ad-1", "type": "ad.loaded"], from: main)
            bridge.show()
            bridge.receive(["adId": "ad-1", "type": "video.start"], from: main)
        case .ended:
            bridge.receive(["adId": "ad-1", "type": "ad.loaded"], from: main)
            bridge.show()
            bridge.hide()
        }
        let setUp = events.count
        return (bridge, { Array(events.dropFirst(setUp)) })
    }

    private func outcome(of type: String, _ body: [String: Any], in stage: Stage) -> Outcome {
        let (bridge, events) = bridge(in: stage)
        let before = bridge.state
        var message: [String: Any] = ["adId": "ad-1", "type": type]
        body.forEach { message[$0.key] = $0.value }
        bridge.noteTouch()
        bridge.receive(message, from: main)
        let delivered = events()
        if delivered.isEmpty {
            #expect(bridge.state == before, "\(type) in \(stage): a dropped message leaves the state")
            return .drop
        }
        #expect(delivered.count == 1, "\(type) in \(stage): one event")
        if case .loaded = delivered[0] { return bridge.state == .loaded ? .loaded : .deliver }
        if bridge.state == .ended, before != .ended { return .end }
        return .deliver
    }

    @Test func everyMessageInEveryState() {
        for (type, body) in Self.messages {
            let row = Stage.allCases.map { outcome(of: type, body, in: $0) }
            #expect(row == Self.expected[type], "\(type): loading, loaded, shown, ended")
        }
    }
}
}
