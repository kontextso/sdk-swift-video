import Foundation
@testable import KontextVideoSDK
import Testing

/// `EventHistory`: the last events, kept as `DebugReporter` recorded them, so an error report's history reads as
/// the debug log does.
extension SerialSuites {
@Suite
@MainActor
struct EventHistoryTests {
    init() { EventHistory.clear() }

    private func event(_ name: String, properties: [String: ReportFormat.Value]? = nil) -> DebugReporter.Event {
        DebugReporter.Event(occurredAt: "t", name: name, sessionId: nil, bidId: nil, level: nil, properties: properties)
    }

    @Test func keepsTheLastEventsOnly() {
        for index in 0..<(EventHistory.historyLength + 5) {
            EventHistory.record(event("e\(index)"))
        }
        let recent = EventHistory.recent()
        #expect(recent.count == EventHistory.historyLength && recent.first?.name == "e5")
        EventHistory.clear()
        #expect(EventHistory.recent().isEmpty)
    }

    @Test func theReportsHistoryIsTheEventAsRecorded() throws {
        EventHistory.record(event("ads.response", properties: ["format": "pause", "filled": true, "held": 2, "secret": "kept"]))
        let kept = try #require(EventHistory.recent().last)
        #expect(kept.name == "ads.response" && kept.properties?.count == 4, "every property stays, listed or not: the server stores what it is sent")
        #expect(kept.properties?["secret"].map { "\($0)" } == "kept")
        #expect(kept.properties?["held"].map { "\($0)" } == "2")
    }

    @Test func aDebugEventKeepsItsStringsSmallFromTheStart() throws {
        let huge = String(repeating: "i", count: 100_000)
        DebugReporter.shared.event("ad.huge", bidId: huge, properties: ["format": .string(huge), "count": 3])
        let kept = try #require(EventHistory.recent().last)
        #expect(kept.bidId?.utf8.count == 64, "a server's huge id is not kept whole; 64 bytes, as on Android")
        if case .string(let format)? = kept.properties?["format"] { #expect(format.utf8.count == 64) } else { Issue.record("format kept") }
        #expect(kept.properties?["count"].map { "\($0)" } == "3")
    }

    @Test func aConsoleLineIsKeptWholeWithoutItsURLsQueries() async throws {
        DebugReporter.forward(.warning, "frame ab12: page https://ads.kontext.so/v2/frame/x?ifa=secret&f=1 answered 410, then https://a.b/c")
        try await Task.sleep(seconds: 0.05)
        let kept = try #require(EventHistory.recent().last)
        #expect(kept.name == "log" && kept.level == .warning)
        if case .string(let message)? = kept.properties?["message"] {
            #expect(message == "frame ab12: page https://ads.kontext.so/v2/frame/x answered 410, then https://a.b/c")
        } else { Issue.record("message kept") }
    }
}
}
