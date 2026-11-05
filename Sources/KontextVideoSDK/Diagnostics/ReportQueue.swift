import Foundation

/// The error reports waiting to be sent, and the batches made from them; no tasks, no sending. At most
/// `maxBuffered` reports and `maxBufferedBytes` wait: past either the oldest go, counted in `dropped`, which the
/// next batch says. A batch takes the oldest reports, at most `maxBatch`, whose whole body stays within
/// `maxBatchBytes`; a report that does not fit even alone is dropped and counted.
struct ReportQueue {
    /// One batch, retried byte for byte until it leaves or the server refuses it: the server dedupes by `batchId`.
    struct Batch {
        let count: Int
        let body: Data
    }

    /// Reports kept while they cannot leave; beyond this the oldest go, counted in `dropped`.
    static let maxBuffered = 200
    /// Reports in one request.
    static let maxBatch = 50
    /// Encoded bytes of the reports waiting, and of one whole request body, envelope included: the counts alone
    /// do not bound memory or upload size.
    static let maxBufferedBytes = 256 * 1024
    static let maxBatchBytes = 64 * 1024

    /// The reports waiting, oldest first.
    private(set) var reports: [ErrorReport] = []
    /// The encoded size of each waiting report, in `reports`' order, and their sum.
    private var sizes: [Int] = []
    private var bufferedBytes = 0
    /// Reports dropped for room and not yet sent in a batch.
    private(set) var dropped = 0

    var isEmpty: Bool { reports.isEmpty }

    /// A report's encoded size.
    static func size(of report: ErrorReport) -> Int {
        (try? JSONEncoder().encode(report).count) ?? 0
    }

    /// Queues `report`; one over `maxBatchBytes` alone is dropped and counted. Says whether it was queued.
    @discardableResult
    mutating func add(_ report: ErrorReport) -> Bool {
        let size = Self.size(of: report)
        // Every field is capped, so this cannot happen; if it ever does, the report goes rather than the budgets.
        guard size <= Self.maxBatchBytes else {
            dropped += 1
            return false
        }
        reports.append(report)
        sizes.append(size)
        bufferedBytes += size
        while reports.count > Self.maxBuffered || (bufferedBytes > Self.maxBufferedBytes && reports.count > 1) {
            remove(1)
            dropped += 1
        }
        return true
    }

    /// Everything goes, the count of dropped ones too.
    mutating func clear() {
        reports.removeAll()
        sizes.removeAll()
        bufferedBytes = 0
        dropped = 0
    }

    /// The oldest waiting reports as one finished request body: up to `maxBatch` of them, and as many as fit in
    /// `maxBatchBytes` with the envelope and the separators, the size of the whole body being what is limited.
    /// `envelope` encodes a request of the given reports and dropped count. The rest wait for the next batch. A
    /// report that cannot fit even alone is dropped and counted. `nil` when nothing is left to send; a batch made
    /// says the dropped count, which starts again from 0.
    mutating func makeBatch(envelope: (_ reports: [ErrorReport], _ dropped: Int) -> Data?) -> Batch? {
        while !reports.isEmpty {
            // `"errors":[]` holds the reports, one byte between each two: the size is known before encoding.
            guard let empty = envelope([], dropped)?.count else { return nil }
            var count = 0
            var bytes = empty
            while count < min(reports.count, Self.maxBatch), bytes + sizes[count] + (count > 0 ? 1 : 0) <= Self.maxBatchBytes {
                bytes += sizes[count] + (count > 0 ? 1 : 0)
                count += 1
            }
            if count == 0 {
                Logger.debug("error report of \(sizes[0]) bytes dropped, it cannot fit a batch")
                remove(1)
                dropped += 1
                continue
            }
            // Checked on the encoded body itself: the arithmetic above is the plan, the body is what leaves.
            var body = envelope(Array(reports.prefix(count)), dropped)
            while count > 1, (body?.count ?? 0) > Self.maxBatchBytes {
                count -= 1
                body = envelope(Array(reports.prefix(count)), dropped)
            }
            guard let body, body.count <= Self.maxBatchBytes else {
                remove(1)
                dropped += 1
                continue
            }
            remove(count)
            dropped = 0
            return Batch(count: count, body: body)
        }
        return nil
    }

    private mutating func remove(_ count: Int) {
        reports.removeFirst(count)
        bufferedBytes -= sizes.prefix(count).reduce(0, +)
        sizes.removeFirst(count)
    }
}
