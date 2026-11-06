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

    @Test func theOldestGoPastTheBufferedBytesAndAreCounted() {
        var queue = ReportQueue()
        let large = String(repeating: "b", count: 20_000)
        let size = ReportQueue.size(of: report(large))
        let fit = ReportQueue.maxBufferedBytes / size
        for index in 0..<(fit + 2) { queue.add(report(large + "\(index % 10)")) }
        #expect(queue.reports.count == fit && queue.dropped == 2, "\(queue.reports.count) kept of \(fit + 2)")
        #expect(queue.reports.first?.detail?.hasSuffix("2") == true, "the oldest two went")
    }

    @Test func aReportOverTheBatchBudgetAloneIsNeverQueued() {
        var queue = ReportQueue()
        let tooLarge = report(String(repeating: "z", count: ReportQueue.maxBatchBytes))
        #expect(ReportQueue.size(of: tooLarge) > ReportQueue.maxBatchBytes)
        let queued = queue.add(tooLarge)
        #expect(!queued && queue.isEmpty && queue.dropped == 1)
        queue.add(report())
        #expect(queue.reports.count == 1 && queue.dropped == 1, "the next one is kept, the count waits for a batch")
    }

    @Test func aReportThatFitsAloneButNotInItsEnvelopeIsDroppedAndCounted() throws {
        var queue = ReportQueue()
        // Exactly the batch budget alone: with the envelope around it, it can never leave.
        let head = ReportQueue.size(of: report(""))
        let exact = report(String(repeating: "e", count: ReportQueue.maxBatchBytes - head))
        #expect(ReportQueue.size(of: exact) == ReportQueue.maxBatchBytes)
        let queued = queue.add(exact)
        #expect(queued)
        let none = queue.makeBatch(envelope: envelope)
        #expect(none == nil && queue.isEmpty && queue.dropped == 1, "nothing else waits: no batch, the count kept for the next")
        queue.add(exact)
        queue.add(report("after"))
        let made = queue.makeBatch(envelope: envelope)
        let batch = try #require(made)
        let body = try #require(try JSONSerialization.jsonObject(with: batch.body) as? [String: Any])
        #expect(batch.count == 1 && body["dropped"] as? Int == 2, "the next batch says both")
        #expect(((body["errors"] as? [[String: Any]])?.first?["detail"] as? String) == "after")
    }

    @Test func aBatchFillsTheByteBudgetAndNoFurther() throws {
        // Reports sized so that four of them, the envelope and three commas come as close to the budget as can be.
        let empty = try #require(envelope([], 0)).count
        let perReport = (ReportQueue.maxBatchBytes - empty - 3) / 4
        let detail = String(repeating: "k", count: perReport - ReportQueue.size(of: report("")))
        var queue = ReportQueue()
        for _ in 0..<5 { queue.add(report(detail)) }
        let made = queue.makeBatch(envelope: envelope)
        let batch = try #require(made)
        #expect(batch.count == 4 && batch.body.count == empty + 4 * perReport + 3, "\(batch.count) reports, \(batch.body.count) bytes")
        #expect(batch.body.count <= ReportQueue.maxBatchBytes && ReportQueue.maxBatchBytes - batch.body.count < 4, "within 3 bytes of the budget")
        #expect(queue.reports.count == 1)
    }

    @Test func batchesKeepTheOrderTheReportsCameIn() throws {
        var queue = ReportQueue()
        for index in 0..<(ReportQueue.maxBatch + 5) { queue.add(report("\(index)")) }
        var details: [String] = []
        while let batch = queue.makeBatch(envelope: envelope) {
            let body = try #require(try JSONSerialization.jsonObject(with: batch.body) as? [String: Any])
            details += (body["errors"] as? [[String: Any]] ?? []).compactMap { $0["detail"] as? String }
        }
        #expect(details == (0..<(ReportQueue.maxBatch + 5)).map(String.init))
    }

    @Test func anEnvelopeThatCannotBeEncodedMakesNoBatchAndKeepsTheReports() {
        var queue = ReportQueue()
        queue.add(report())
        let none = queue.makeBatch { _, _ in nil }
        #expect(none == nil && queue.reports.count == 1)
    }
}
