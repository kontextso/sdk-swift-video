import Foundation
@testable import KontextVideoSDK
import Testing

/// `ErrorReport`'s own pieces, pure: a failed request as the report's fields, the cause, the fields `make` caps.
/// What is reported when, and sent how, is ErrorReporterTests'.
@Suite
@MainActor
struct ErrorReportTests {
    @Test func aFailedRequestAsTheReportsFieldsForEveryKindOfFailure() {
        let http = ErrorReport.FailedRequest(APIError.http(status: 503, errors: []))
        #expect(http.httpStatus == 503 && http.cause == nil && http.detail == nil)
        let transport = ErrorReport.FailedRequest(APIError.transport(URLError(.timedOut)))
        #expect(transport.httpStatus == nil && transport.cause?.domain == NSURLErrorDomain
                && transport.cause?.code == URLError.Code.timedOut.rawValue && transport.detail == "network")
        let corrupted = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        let decoding = ErrorReport.FailedRequest(APIError.decoding(corrupted))
        #expect(decoding.httpStatus == nil && decoding.cause == ErrorReport.Cause(corrupted) && decoding.detail == nil,
                "the decoding error itself, as the system bridges it: \(String(describing: decoding.cause))")
        // Not an APIError (a bare system error): its own domain and code, nothing else.
        let other = ErrorReport.FailedRequest(NSError(domain: "Other", code: -7))
        #expect(other.httpStatus == nil && other.cause == ErrorReport.Cause(NSError(domain: "Other", code: -7)) && other.detail == nil)
        #expect(other.cause?.code == -7)
    }

    @Test func theCausesDomainIsCappedAndAnHTTPStatusIsItsOwnDomain() {
        let long = ErrorReport.Cause(NSError(domain: String(repeating: "d", count: 500), code: 1))
        #expect(long.domain.utf8.count == ReportFormat.maxFieldLength && long.code == 1)
        let status = ErrorReport.Cause(httpStatus: 404)
        #expect(status.domain == "http" && status.code == 404)
    }

    @Test func makeCapsEveryStringItKeeps() {
        let long = String(repeating: "x", count: 300)
        let report = ErrorReport.make(.creativeFailed, requestId: long, sessionId: long, bidId: long, vastCode: 405, httpStatus: 500, detail: long)
        for field in [report.requestId, report.sessionId, report.bidId, report.detail] {
            #expect(field?.utf8.count == ReportFormat.maxFieldLength)
        }
        #expect(report.code == "ad.creative_failed" && report.vastCode == 405 && report.httpStatus == 500)
        #expect(UUID(uuidString: report.id) != nil && report.id == report.id.lowercased())
        let bare = ErrorReport.make(.configFailed)
        #expect(bare.requestId == nil && bare.bidId == nil && bare.detail == nil && bare.cause == nil)
        #expect(report.id != bare.id, "a new id per report")
    }
}
