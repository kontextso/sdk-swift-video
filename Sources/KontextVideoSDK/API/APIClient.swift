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

/// The ad server's error body (JSON:API-shaped, see the API's Common page). Decoded leniently: every
/// field is optional and `code`, the one field the SDK acts on (`unknownPlacement`,
/// `placementFormatMismatch`), reads `unknown` when absent, so a server that sends less than the
/// contract still gets its message into the log and never makes the SDK drop the whole body.
struct APIErrorResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let status: String?
        let code: String
        /// A short human-readable summary, for the log.
        let title: String?
        let detail: String?

        private enum CodingKeys: String, CodingKey {
            case status, code, title, detail
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? "unknown"
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        }

        init(status: String? = nil, code: String, title: String? = nil, detail: String? = nil) {
            self.status = status
            self.code = code
            self.title = title
            self.detail = detail
        }
    }

    let errors: [Item]
    /// Milliseconds; present on 429 and 5xx. Not acted on today.
    let retryAfter: Int?
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
