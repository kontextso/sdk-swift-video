import Foundation

/// Why a request to the ad server failed.
enum APIError: Error, CustomStringConvertible {
    /// The request never got an answer: no network, timeout, DNS.
    case transport(URLError)
    /// The server answered with an error status; `errors` is its error body, when it sent one.
    case http(status: Int, errors: [ErrorResponse.Item])
    /// The answer was not the JSON we expected.
    case decoding(Error)

    /// Transport failures and server-side errors may succeed on a retry; client errors (4xx) will not.
    var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .http(let status, _): return status >= 500 || status == 429
        case .decoding: return false
        }
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
