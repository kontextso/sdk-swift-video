import Foundation

/// Why a request to the ad server failed.
enum APIError: Error, CustomStringConvertible {
    /// The request never got an answer: no network, timeout, DNS.
    case transport(URLError)
    /// The server answered with an error status; `errors` is its error body, when it sent one.
    case http(status: Int, errors: [ErrorResponse.Item])
    /// The answer was not the JSON we expected.
    case decoding(Error)

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
