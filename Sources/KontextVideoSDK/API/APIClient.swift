import Foundation

/// Why a request to the ad server failed.
enum APIError: Error, CustomStringConvertible {
    /// The request never got an answer: no network, timeout, DNS.
    case transport(URLError)
    /// The server answered with an error status; `errors` is its error body, when it sent one.
    case http(status: Int, errors: [APIErrorResponse.Item])
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
        case .http(let status, let errors): return "HTTP \(status)" + (errors.isEmpty ? "" : ": " + errors.map { $0.title ?? $0.code }.joined(separator: "; "))
        case .decoding(let error): return "decoding error: \(error)"
        }
    }
}

/// Sends JSON requests to the ad server's `/v2/` routes.
struct APIClient: Sendable {
    static let defaultTimeout: TimeInterval = 10

    let baseURL: URL
    let session: URLSession

    @MainActor
    init(baseURL: URL) {
        self.baseURL = baseURL
        session = Environment.session
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        timeout: TimeInterval = APIClient.defaultTimeout
    ) async throws -> Response {
        try Task.checkCancellation()   // a task cancelled before this point sends nothing
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let errors = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.errors ?? []
            throw APIError.http(status: status, errors: errors)
        }
        if data.isEmpty, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

/// What a route with no body answers (`/debug`, a `204`). `post` is generic in what it returns and the
/// caller names the type, so a route that returns nothing still needs a `Decodable` type to name;
/// `post` returns one of these for an empty body without touching the decoder. The alternative, a
/// second `post` without a return value, would repeat the request building and the error mapping.
struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}
