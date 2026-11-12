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
        /// Held until the test opens it: for races, instead of guessing a delay. The request is recorded at once.
        var gate: Gate?
        /// A body of this many bytes, sent in 64 KiB pieces after the head, as a large download arrives: with
        /// a `Content-Length`, or chunked (no length) when `chunked`. The head goes first; the body only if the
        /// client has not cancelled within `streamGrace` seconds. What was delivered lands in `streams`.
        var streamedBytes: Int?
        var chunked = false

        /// `streamedBytes` of zeros.
        static func streamed(_ bytes: Int, chunked: Bool = false) -> Response {
            var response = Response(status: 200)
            response.streamedBytes = bytes
            response.chunked = chunked
            return response
        }

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }

        static func empty(_ status: Int = 204) -> Response { Response(status: status) }
        static func failure(_ code: URLError.Code) -> Response { Response(status: 0, error: URLError(code)) }
    }

    /// Holds gated responses until `open()`; opening twice, or a response that arrives after, delivers at once.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiting: [() -> Void] = []

        var isOpen: Bool { lock.withLock { opened } }

        func open() {
            let released: [() -> Void] = lock.withLock {
                opened = true
                defer { waiting = [] }
                return waiting
            }
            released.forEach { DispatchQueue.global().async(execute: $0) }
        }

        fileprivate func whenOpen(_ work: @escaping () -> Void) {
            let now: Bool = lock.withLock {
                if !opened { waiting.append(work) }
                return opened
            }
            if now { DispatchQueue.global().async(execute: work) }
        }
    }

    struct Recorded: @unchecked Sendable {
        let request: URLRequest
        let body: [String: Any]?
        /// The bytes as sent.
        var rawBody = Data()
        /// When the request reached the server.
        var receivedAt = Date()
        var path: String { request.url?.path ?? "" }
        var query: [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
    }

    /// One streamed response: the path, the body bytes delivered, and whether the client cancelled first.
    struct Stream: Sendable {
        let path: String
        let delivered: Int
        let cancelled: Bool
    }

    /// How long a streamed response waits for the client to cancel before it sends the body.
    static let streamGrace: TimeInterval = 5

    private var recordedStreams: [Stream] = []

    var streams: [Stream] {
        lock.lock(); defer { lock.unlock() }
        return recordedStreams
    }

    fileprivate func record(_ stream: Stream) {
        lock.lock(); defer { lock.unlock() }
        recordedStreams.append(stream)
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

    /// Beacons as `(event, query)` in arrival order, from the mock-shaped `/events/{bidId}/{event}` URLs.
    var beacons: [(bidId: String, event: String, query: [String: String])] {
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

    /// The server installed last. Read from URL-loading threads while the main thread installs the next
    /// one, so every access goes through `registryLock`: an unguarded dictionary here crashed the test host.
    static var current: StubServer? {
        get { registryLock.withLock { storedCurrent } }
        set { registryLock.withLock { storedCurrent = newValue } }
    }
    nonisolated(unsafe) private static var storedCurrent: StubServer?
    /// Every installed server by its marker, so a request made on an older session (a beacon a previous
    /// test's `VideoAds` fires from `deinit`, on a background thread) reaches its own server, never the
    /// one the next test installed meanwhile. Guarded by `registryLock`.
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let registryLock = NSLock()
    private static let markerHeader = "X-Kontext-Stub"
    private let marker = UUID().uuidString

    /// Makes this server the SDK's session.
    @MainActor
    func install() {
        StubServer.current = self
        StubServer.registryLock.withLock { StubServer.servers[marker] = self }
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
        let marker = request.value(forHTTPHeaderField: markerHeader)
        return registryLock.withLock { marker.flatMap { servers[$0] } ?? storedCurrent }
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
        if let size = response.streamedBytes {
            return stream(size, chunked: response.chunked, to: server)
        }
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
        if let gate = response.gate {
            gate.whenOpen(deliver)
        } else if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    private let stopped = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var isStopped = false

    override func stopLoading() {
        stateLock.withLock { isStopped = true }
        stopped.signal()
    }

    /// The head, then, unless the client cancelled within the grace period, the body piece by piece, stopping
    /// as soon as the client does.
    private func stream(_ size: Int, chunked: Bool, to server: StubServer) {
        let path = request.url?.path ?? ""
        var headers = ["Content-Type": "application/octet-stream"]
        if chunked { headers["Transfer-Encoding"] = "chunked" } else { headers["Content-Length"] = String(size) }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            if stopped.wait(timeout: .now() + StubServer.streamGrace) == .success {
                return server.record(.init(path: path, delivered: 0, cancelled: true))
            }
            let piece = Data(count: 64 * 1024)
            var delivered = 0
            while delivered < size {
                if stateLock.withLock({ isStopped }) {
                    return server.record(.init(path: path, delivered: delivered, cancelled: true))
                }
                let next = piece.prefix(min(piece.count, size - delivered))
                client?.urlProtocol(self, didLoad: next)
                delivered += next.count
            }
            client?.urlProtocolDidFinishLoading(self)
            server.record(.init(path: path, delivered: delivered, cancelled: false))
        }
    }
}
