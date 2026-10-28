import Foundation
@testable import KontextVideoSDK

/// A scripted ad server behind `URLSession`: every request the SDK sends through `Environment.session`
/// is answered by a route matcher, and recorded. One instance per test; `install()` makes it the SDK's
/// session, `reset()` in the test's teardown restores production.
///
/// `URLProtocol` subclasses are process-global, so the active server is a static; suites that use it
/// are serialized.
final class StubServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var body = Data()
        var error: Error?
        var delay: TimeInterval = 0

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }

        static func empty(_ status: Int = 204) -> Response { Response(status: status) }
        static func failure(_ code: URLError.Code) -> Response { Response(status: 0, error: URLError(code)) }
    }

    struct Recorded: @unchecked Sendable {
        let request: URLRequest
        let body: [String: Any]?
        /// The bytes as sent.
        var rawBody = Data()
        var path: String { request.url?.path ?? "" }
        var query: [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
    }

    private let lock = NSLock()
    private var routes: [(matches: (URLRequest) -> Bool, respond: (Recorded) -> Response)] = []
    private var recorded: [Recorded] = []

    let baseURL = URL(string: "https://ads.test")!

    /// Answers requests whose path starts with `path` (`/v2/config`, `/events/`, ...). Later routes win.
    func on(_ path: String, _ respond: @escaping (Recorded) -> Response) {
        lock.lock(); defer { lock.unlock() }
        routes.append(({ $0.url?.path.hasPrefix(path) == true }, respond))
    }

    func on(_ path: String, _ response: Response) {
        on(path) { _ in response }
    }

    var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requests(to path: String) -> [Recorded] {
        requests.filter { $0.path.hasPrefix(path) }
    }

    /// Beacons as `(event, query)` in arrival order, from the mock-shaped `/events/{adId}/{event}` URLs.
    var beacons: [(adId: String, event: String, query: [String: String])] {
        requests(to: "/events/").compactMap { recorded in
            let parts = recorded.path.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return (String(parts[1]), String(parts[2]), recorded.query)
        }
    }

    fileprivate func handle(_ request: URLRequest) -> Response {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let recordedRequest = Recorded(request: request, body: parsed, rawBody: body)
        lock.lock()
        recorded.append(recordedRequest)
        let route = routes.last { $0.matches(request) }
        lock.unlock()
        guard let route else { return Response(status: 404) }
        return route.respond(recordedRequest)
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: Installation

    nonisolated(unsafe) static var current: StubServer?
    /// Every installed server by its marker, so a request made on an older session (a beacon a previous
    /// test's `VideoAds` fires from `deinit`, on a background thread) reaches its own server, never the
    /// one the next test installed meanwhile.
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let markerHeader = "X-Kontext-Stub"
    private let marker = UUID().uuidString

    /// Makes this server the SDK's session.
    @MainActor
    func install() {
        StubServer.current = self
        StubServer.servers[marker] = self
        Environment.session = makeSession()
    }

    /// The SDK's own session policy with this server behind it; `deadline` shortens the overall bound.
    @MainActor
    func makeSession(deadline: TimeInterval = APIClient.defaultTimeout) -> URLSession {
        let marker = marker
        return Environment.makeSession(deadline: deadline) { configuration in
            configuration.protocolClasses = [StubProtocol.self]
            configuration.httpAdditionalHeaders = [StubServer.markerHeader: marker]
        }
    }

    @MainActor
    static func uninstall() {
        current = nil
        Environment.reset()
    }

    /// The server a request belongs to: the one its session was created for, else the current one.
    fileprivate static func server(for request: URLRequest) -> StubServer? {
        if let marker = request.value(forHTTPHeaderField: markerHeader), let server = servers[marker] { return server }
        return current
    }
}

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = StubServer.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = server.handle(request)
        let deliver = { [self] in
            if let error = response.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}
