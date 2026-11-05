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

/// Reading what a request threw as the public `RequestFailure`: next to the errors it reads.
extension VideoAdError.RequestFailure {
    /// From what the request threw: `APIClient`'s errors, and a bare `URLError` the same way. Cancellation
    /// never reaches the app (only `destroy()` or the release cancels a request, and that throws
    /// `destroyed`), so a cancelled transfer reads as `offline`. Anything else is a request the SDK
    /// could not complete as the contract says: `badResponse`.
    init(_ error: Error) {
        switch error {
        case APIError.transport(let urlError): self.init(urlError.code)
        case APIError.http(let status, _): self = status > 0 ? .server(status: status) : .badResponse
        case APIError.decoding: self = .badResponse
        case let urlError as URLError: self.init(urlError.code)
        default: self = .badResponse
        }
    }

    /// A transport failure: an answer that arrived broken is `badResponse`, a timeout `timedOut`, and
    /// every other way of not getting through `offline`.
    init(_ code: URLError.Code) {
        switch code {
        case .timedOut:
            self = .timedOut
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData,
             .dataLengthExceedsMaximum, .zeroByteResource:
            self = .badResponse
        default:
            self = .offline
        }
    }
}
