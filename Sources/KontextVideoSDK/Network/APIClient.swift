import Foundation

/// Sends JSON requests to the ad server's `/v2/` routes.
struct APIClient: Sendable {
    static let defaultTimeout: TimeInterval = 10
    /// The largest answer read, error bodies included. Ours are a few kilobytes; a broken server or CDN that
    /// sends hundreds of megabytes inside the deadline must not fill the app's memory, nor the decoder's.
    static let maxResponseBytes = 5 * 1024 * 1024

    let baseURL: URL
    let session: URLSession
    /// `maxResponseBytes`, smaller in tests.
    let responseLimit: Int

    @MainActor
    init(baseURL: URL, session: URLSession? = nil, responseLimit: Int = APIClient.maxResponseBytes) {
        self.baseURL = baseURL
        self.session = session ?? Environment.session
        self.responseLimit = responseLimit
    }

    /// The body as `post` sends it. Sorted keys: the same value always encodes to the same bytes, for logs and diffs.
    static func encode(_ body: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(body)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        timeout: TimeInterval = APIClient.defaultTimeout
    ) async throws -> Response {
        try Task.checkCancellation()   // a task cancelled before this point sends nothing
        return try await post(path, encodedBody: Self.encode(body), timeout: timeout)
    }

    /// The same with a body already encoded: a request retried byte for byte, or one sized before it leaves.
    func post<Response: Decodable>(
        _ path: String,
        encodedBody: Data,
        timeout: TimeInterval = APIClient.defaultTimeout
    ) async throws -> Response {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encodedBody
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            // Redirects are followed as URLSession does by default, the body included (a 307 or 308 re-sends
            // the POST): deliberate. The base URL is ours and the routes do not redirect today; a redirect
            // would be our own server's, for example a move behind a new host, and refusing it would turn
            // that into an outage of every installed SDK. Never from `https` to `http` (`RedirectLimit`).
            (data, response) = try await load(request)
        } catch let error as URLError {
            throw APIError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Through the same depth guard as a success: an error body nested 100 000 deep must not crash either.
            let errors = (try? Self.decode(ErrorResponse.self, from: data))?.errors ?? []
            throw APIError.http(status: status, errors: errors)
        }
        // A route that answers nothing ignores whatever body a 2xx has (`OK`, a proxy's page): the request arrived.
        // Decoding it would fail and make the caller retry a delivered batch forever.
        if let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try Self.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// The deepest nesting of arrays and objects a server answer may have, as the Kotlin SDK reads it. No answer
    /// of the contract comes near it. Checked here for every iOS version: the platform's decoder has this limit
    /// only from iOS 17, and decodes deeper answers before it.
    static let maxNestingDepth = 512

    /// A server answer decoded: refused as `dataCorrupted` when nested deeper than `maxNestingDepth`, read
    /// before decoding, so a deep answer costs no stack. The decoder is recursive, one call per level: an
    /// answer like `[[[[…]]]]` nested 100 000 deep would overflow the stack and crash the app from an ad
    /// request, which no `catch` stops. The measure is one pass with no recursion; brackets inside strings
    /// (text such as `"Watch [Episode 2]"`, escaped quotes included) are not counted, only the JSON's own
    /// structure is. A real answer nests about 6 deep.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var depth = 0
        var isInString = false
        var isEscaped = false
        for byte in data {
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                isInString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > maxNestingDepth {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "nested deeper than \(maxNestingDepth) levels"))
                }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
            default:
                break
            }
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

extension APIClient {
    /// The answer, cut at `maxResponseBytes`: a longer one fails as `dataLengthExceedsMaximum`, a transport
    /// error. Streamed where the OS can (iOS 15), so nothing past the limit is held; on iOS 14 the body is
    /// read whole and refused afterwards, as `URLSession` has no streaming `async` call there.
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let limit = responseLimit
        guard #available(iOS 15.0, *) else {
            let (data, response) = try await session.data(for: request)
            guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            return (data, response)
        }
        let (bytes, response) = try await session.bytes(for: request)
        // Stopping the task ends the transfer; the bytes already received are dropped with it.
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return (data, response)
    }
}

/// What a route with no body answers (`/debug`, a `204`). `post` is generic in what it returns and the
/// caller names the type, so a route that returns nothing still needs a `Decodable` type to name;
/// `post` returns one of these for any 2xx, whatever its body, without touching the decoder. The alternative, a
/// second `post` without a return value, would repeat the request building and the error mapping.
struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}
