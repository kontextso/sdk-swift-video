import Foundation

/// Sends JSON requests to the ad server's `/v2/` routes.
struct APIClient: Sendable {
    static let defaultTimeout: TimeInterval = 10

    let baseURL: URL
    let session: URLSession

    @MainActor
    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? Environment.session
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
        // Sorted keys: the same value always encodes to the same bytes, for logs and diffs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            // Redirects are followed as URLSession does by default, the body included (a 307 or 308 re-sends
            // the POST): deliberate. The base URL is ours and the routes do not redirect today; a redirect
            // would be our own server's, for example a move behind a new host, and refusing it would turn
            // that into an outage of every installed SDK.
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let errors = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.errors ?? []
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
