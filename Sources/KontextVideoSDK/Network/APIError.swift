import Foundation

/// Why a request to the ad server failed.
enum APIError: Error, CustomStringConvertible {
    /// The request never got an answer: no network, timeout, DNS.
    case transport(URLError)
    /// The server answered with an error status; `errors` is its error body, when it sent one.
    case http(status: Int, errors: [ErrorResponse.Item])
    /// The answer was not the JSON we expected.
    case decoding(Error)

    /// Transport failures, server errors (5xx) and rate limiting (429) may succeed on a retry; the other
    /// client errors and a decoding failure will not. Every transport failure counts, a certificate or
    /// URL error included: the URL is ours and fixed, and a captive portal or a bad network makes any of
    /// them, which the next network clears. A cancelled request is not a failure: whoever cancelled it
    /// does not want it sent again.
    var isRetryable: Bool {
        switch self {
        case .transport(let error): return error.code != .cancelled
        case .http(let status, _): return (500..<600).contains(status) || status == 429
        case .decoding: return false
        }
    }

    /// The answer arrived but did not match the contract.
    var isDecoding: Bool {
        if case .decoding = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .transport(let error): return "transport error: \(error.localizedDescription)"
        case .http(let status, let errors):
            let summaries = errors.compactMap(\.summary)
            return "HTTP \(status)" + (summaries.isEmpty ? "" : ": " + summaries.joined(separator: "; "))
        case .decoding(let error): return "decoding error: \(error)"
        }
    }
}
