import Foundation
@testable import KontextVideoSDK
import Testing

/// `ReportQueue`, pure: the buffer's limits by count and bytes, the oldest dropped and counted, and batches within
/// the count and byte limits.
@Suite
@MainActor
struct ReportQueueTests {
    private func report(_ detail: String = "x") -> ErrorReport {
        ErrorReport(id: UUID().uuidString, createdAt: "2026-11-05T00:00:00.000Z", code: "ad.creative_failed", stage: .load,
                    requestId: nil, sessionId: nil, adId: nil, vastCode: nil, httpStatus: nil, underlying: nil,
                    detail: detail, recovery: nil, history: [])
    }

    /// A body as the reporter's: the reports in an array, with the dropped count.
    private struct Envelope: Encodable {
        let dropped: Int
        let errors: [ErrorReport]
    }

    private func envelope(_ reports: [ErrorReport], _ dropped: Int) -> Data? {
        try? JSONEncoder().encode(Envelope(dropped: dropped, errors: reports))
    }

    @Test func theOldestGoPastTheCountAndAreCounted() {
        var queue = ReportQueue()
        for index in 0..<(ReportQueue.maxBuffered + 3) { queue.add(report("\(index)")) }
        #expect(queue.reports.count == ReportQueue.maxBuffered && queue.dropped == 3)
        #expect(queue.reports.first?.detail == "3", "the oldest went")
    }

    @Test func aBatchTakesAtMostMaxBatchAndSaysTheDroppedCountOnce() throws {
        var queue = ReportQueue()
        for index in 0..<(ReportQueue.maxBuffered + 1) { queue.add(report("\(index)")) }
        let made = queue.makeBatch(envelope: envelope)
        let first = try #require(made)
        #expect(first.count == ReportQueue.maxBatch && first.body.count <= ReportQueue.maxBatchBytes)
        let body = try #require(try JSONSerialization.jsonObject(with: first.body) as? [String: Any])
        #expect(body["dropped"] as? Int == 1 && queue.dropped == 0, "the batch says it, then it starts again")
        #expect(queue.reports.count == ReportQueue.maxBuffered - ReportQueue.maxBatch)
    }

    @Test func aBatchStaysWithinTheByteBudget() throws {
        var queue = ReportQueue()
        let large = String(repeating: "y", count: 4000)
        for _ in 0..<40 { queue.add(report(large)) }
        var total = 0
        while let batch = queue.makeBatch(envelope: envelope) {
            #expect(batch.body.count <= ReportQueue.maxBatchBytes)
            total += batch.count
        }
        #expect(total == 40 && queue.isEmpty)
    }

    @Test func nothingWaitingMakesNoBatch() {
        var queue = ReportQueue()
        let none = queue.makeBatch(envelope: envelope)
        #expect(none == nil)
        queue.add(report())
        queue.clear()
        let afterClear = queue.makeBatch(envelope: envelope)
        #expect(queue.isEmpty && queue.dropped == 0 && afterClear == nil)
    }
}
