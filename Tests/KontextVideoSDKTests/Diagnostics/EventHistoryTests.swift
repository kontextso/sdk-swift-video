@testable import KontextVideoSDK
import Testing

/// `EventHistory`: the last events, and the history an error report carries: listed keys only, strings capped.
extension SerialSuites {
@Suite
@MainActor
struct EventHistoryTests {
    init() { EventHistory.clear() }

    @Test func keepsTheLastEventsOnly() {
        for index in 0..<(EventHistory.historyLength + 5) {
            EventHistory.record(createdAt: "t", name: "e\(index)", adId: nil, state: nil)
        }
        let recent = EventHistory.recent()
        #expect(recent.count == EventHistory.historyLength && recent.first?.name == "e5")
        EventHistory.clear()
        #expect(EventHistory.recent().isEmpty)
    }

    @Test func theReportsHistoryHasListedKeysOnlyAndCappedStrings() throws {
        let long = String(repeating: "z", count: 200)
        EventHistory.record(createdAt: "t", name: long, adId: long, state: ["format": .string(long), "secret": "x", "held": 2])
        EventHistory.record(createdAt: "t", name: "bare", adId: nil, state: ["secret": "x"])
        let recent = EventHistory.recent()
        let first = try #require(recent.first)
        #expect(first.name.utf8.count == ReportFormat.maxFieldLength && first.adId?.utf8.count == ReportFormat.maxFieldLength)
        #expect(Set(first.state?.keys ?? [:].keys) == ["format", "held"], "an unlisted key stays on the device")
        if case .string(let format)? = first.state?["format"] { #expect(format.utf8.count == ReportFormat.maxFieldLength) }
        #expect(recent.last?.state == nil, "no listed key: no state")
    }
}
}
