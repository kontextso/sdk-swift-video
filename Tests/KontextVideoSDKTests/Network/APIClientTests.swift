import Foundation
@testable import KontextVideoSDK
import Testing

/// `APIClient.post` against the stub server: the request it builds, and every way an answer maps to
/// `APIError`. Serialized: the stub server is process-global.
extension SerialSuites {
@Suite
@MainActor
struct APIClientTests {
    struct Body: Encodable { let hello: String }
    struct Reply: Decodable { let ok: Bool }

    private let server = StubServer()

    init() {
        SDKHarness.reset()
        server.install()
    }

    private var client: APIClient { APIClient(baseURL: server.baseURL) }

    @Test func postsJSONToTheV2Route() async throws {
        server.on("/v2/ping", .json(["ok": true]))
        let reply: Reply = try await client.post("ping", body: Body(hello: "there"))
        #expect(reply.ok)
        let request = try #require(server.requests.first)
        #expect(request.request.url?.absoluteString == "https://ads.test/v2/ping")
        #expect(request.request.httpMethod == "POST")
        #expect(request.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.request.timeoutInterval == 10)
        #expect(request.body?["hello"] as? String == "there")
    }

    @Test func aRouteThatAnswersNothingTakesAny2xxBody() async throws {
        for body in ["OK", "<html>proxy</html>", "{\"unexpected\":1}", ""] {
            server.on("/v2/error", StubServer.Response(status: 200, body: Data(body.utf8)))
            let _: EmptyResponse = try await client.post("error", body: Body(hello: "x"))
        }
    }

    @Test func aDeeplyNestedErrorBodyGivesTheStatusAlone() async {
        // Before iOS 17 the platform's decoder recurses without a limit: this body would overflow the stack.
        let body = "{\"errors\":" + String(repeating: "[", count: 100_000)
        server.on("/v2/ping", StubServer.Response(status: 500, body: Data(body.utf8)))
        do {
            let _: Reply = try await client.post("ping", body: Body(hello: "x"))
            Issue.record("expected the status")
        } catch let error as APIError {
            guard case .http(let status, let errors) = error else { Issue.record("expected http, got \(error)"); return }
            #expect(status == 500 && errors.isEmpty)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func aSlowAnswerIsCutAtTheDeadlineNotOnlyWhenIdle() async {
        var slow = StubServer.Response.json(["ok": true])
        // The answer comes after 3 s, inside the 10 s idle timeout: only the 0.3 s deadline can end the request
        // with a timeout, and without it the request would succeed. No wall-clock bound, which a loaded CI
        // runner's starved main actor made meaningless (7.6 s for a 0.3 s cut).
        slow.delay = 3
        server.on("/v2/ping", slow)
        let session = server.makeSession(deadline: 0.3)
        #expect(session.configuration.timeoutIntervalForResource == 0.3)
        let client = APIClient(baseURL: server.baseURL, session: session)
        do {
            let _: Reply = try await client.post("ping", body: Body(hello: "x"))
            Issue.record("expected the deadline")
        } catch let error as APIError {
            guard case .transport(let urlError) = error else { Issue.record("expected transport, got \(error)"); return }
            #expect(urlError.code == .timedOut, "cut at the deadline, long before the answer")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func theSameValueEncodesToTheSameBytes() async throws {
        struct Wide: Encodable { let zebra = 1, apple = 2, mango = [3], kiwi = ["b": 1, "a": 2] }
        server.on("/v2/ping", .json(["ok": true]))
        for _ in 0..<20 {
            let _: Reply = try await client.post("ping", body: Wide())
        }
        let bodies = Set(server.requests.map(\.rawBody))
        #expect(bodies.count == 1, "sorted keys: one byte sequence for one value")
        #expect(bodies.first.flatMap { String(bytes: $0, encoding: .utf8) } == #"{"apple":2,"kiwi":{"a":2,"b":1},"mango":[3],"zebra":1}"#)
    }

    @Test func theSDKsSessionIsItsOwnWithADeadlineAndNoCookiesOrCache() {
        Environment.reset()
        let configuration = Environment.session.configuration
        #expect(Environment.session !== URLSession.shared)
        #expect(configuration.timeoutIntervalForResource == APIClient.defaultTimeout)
        #expect(configuration.httpCookieAcceptPolicy == .never && !configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
    }

    @Test func clientErrorCarriesTheServersErrorBody() async {
        server.on("/v2/ping", .json(Fixtures.errors("invalidRequest", title: "video.id is required"), status: 400))
        do {
            let _: Reply = try await client.post("ping", body: Body(hello: "x"))
            Issue.record("expected a throw")
        } catch let error as APIError {
            guard case .http(let status, let errors) = error else { Issue.record("expected http, got \(error)"); return }
            #expect(status == 400)
            #expect(errors.first?.code == "invalidRequest")
            #expect(errors.first?.title == "video.id is required")
            #expect(error.description == "HTTP 400: video.id is required")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// Whatever the server puts in an error body, the client throws `APIError.http` with the status: a
    /// body it cannot read becomes no items, never a different error.
    @Test func anErrorBodyTheClientCannotReadStillGivesTheStatus() async {
        let bodies: [(String, Int, StubServer.Response, String)] = [
            ("{}", 400, .json([String: Any](), status: 400), "HTTP 400"),
            ("errors of the wrong type", 400, .json(["errors": "nope"], status: 400), "HTTP 400"),
            ("an item with nothing in it", 400, .json(["errors": [[String: Any]()]], status: 400), "HTTP 400"),
            ("an HTML gateway page", 502, StubServer.Response(status: 502, body: Data("<html><body>Bad Gateway</body></html>".utf8)), "HTTP 502"),
        ]
        for (name, status, response, description) in bodies {
            server.on("/v2/ping", response)
            do {
                let _: Reply = try await client.post("ping", body: Body(hello: "x"))
                Issue.record("expected a throw for \(name)")
            } catch let error as APIError {
                guard case .http(let got, _) = error else { Issue.record("expected http for \(name), got \(error)"); continue }
                #expect(got == status, "\(name)")
                #expect(error.description == description, "\(name)")
            } catch {
                Issue.record("unexpected \(error) for \(name)")
            }
        }
    }

    @Test func serverErrorsAndRateLimitsAreHTTPErrorsWithTheirStatus() async {
        for status in [500, 503, 429] {
            server.on("/v2/ping", .empty(status))
            do {
                let _: Reply = try await client.post("ping", body: Body(hello: "x"))
                Issue.record("expected a throw for \(status)")
            } catch let error as APIError {
                guard case .http(let got, let errors) = error else { Issue.record("expected http"); return }
                #expect(got == status)
                #expect(errors.isEmpty, "no body, no parsed errors")
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func aTransportFailureIsATransportError() async {
        server.on("/v2/ping", .failure(.notConnectedToInternet))
        do {
            let _: Reply = try await client.post("ping", body: Body(hello: "x"))
            Issue.record("expected a throw")
        } catch let error as APIError {
            guard case .transport(let urlError) = error else { Issue.record("expected transport"); return }
            #expect(urlError.code == .notConnectedToInternet)
            #expect(error.description.hasPrefix("transport error"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func unexpectedJSONIsADecodingError() async {
        server.on("/v2/ping", .json(["nope": 1]))
        do {
            let _: Reply = try await client.post("ping", body: Body(hello: "x"))
            Issue.record("expected a throw")
        } catch let error as APIError {
            guard case .decoding = error else { Issue.record("expected decoding"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// A JSON body of exactly `size` bytes: `{"ok":true,"pad":"xx…"}`.
    private func padded(to size: Int) -> Data {
        let head = Data(#"{"ok":true,"pad":""#.utf8), tail = Data(#""}"#.utf8)
        return head + Data(repeating: UInt8(ascii: "x"), count: size - head.count - tail.count) + tail
    }

    @Test func anAnswerOverTheSizeLimitFailsAsATransportError() async throws {
        #expect(APIClient.maxResponseBytes == 5 * 1024 * 1024)
        // The rule with a small limit: the same code paths, without moving megabytes through the stub server.
        let limit = 4_096
        let small = APIClient(baseURL: server.baseURL, responseLimit: limit)
        server.on("/v2/ping", StubServer.Response(status: 200, body: padded(to: limit)))
        let reply: Reply = try await small.post("ping", body: Body(hello: "x"))
        #expect(reply.ok, "exactly at the limit is read")
        for status in [200, 500] {
            server.on("/v2/ping", StubServer.Response(status: status, body: padded(to: limit + 1)))
            do {
                let _: Reply = try await small.post("ping", body: Body(hello: "x"))
                Issue.record("expected a throw for \(status)")
            } catch let error as APIError {
                guard case .transport(let urlError) = error else { Issue.record("expected transport for \(status), got \(error)"); continue }
                #expect(urlError.code == .dataLengthExceedsMaximum, "one byte over, error bodies too: \(status)")
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    /// The streaming path (iOS 15 and later): a `Content-Length` past the limit is refused at the head, before a
    /// byte of the body; a chunked answer, which has none, by the body's count.
    @Test func anAnswerWhoseLengthIsPastTheLimitStopsAtTheHead() async throws {
        let small = APIClient(baseURL: server.baseURL, responseLimit: 4_096)
        for (path, chunked) in [("/v2/declared", false), ("/v2/undeclared", true)] {
            server.on(path, .streamed(6 * 1024 * 1024, chunked: chunked))
            do {
                let _: Reply = try await small.post(String(path.dropFirst("/v2/".count)), body: Body(hello: "x"))
                Issue.record("expected a throw for \(path)")
            } catch let error as APIError {
                guard case .transport(let urlError) = error else { Issue.record("expected transport for \(path), got \(error)"); continue }
                #expect(urlError.code == .dataLengthExceedsMaximum, "\(path)")
            }
        }
        #expect(await waitUntil(StubServer.streamGrace * 3) { self.server.streams.contains { $0.path == "/v2/declared" } })
        let declared = server.streams.first { $0.path == "/v2/declared" }
        #expect(declared?.cancelled == true && declared?.delivered == 0, "a declared length past the limit stops at the head")
    }

    /// The iOS 14 path, run here on any version: a data delegate that stops the transfer past the limit.
    @Test func theCappedLoadStopsAnAnswerPastTheLimitWhileItArrives() async throws {
        let limit = 4_096
        var request = URLRequest(url: server.baseURL.appendingPathComponent("v2/ping"))
        request.httpMethod = "POST"
        server.on("/v2/ping", StubServer.Response(status: 200, body: padded(to: limit)))
        let (data, response) = try await APIClient.loadCapped(request, over: Environment.session, limit: limit)
        #expect(data == padded(to: limit) && (response as? HTTPURLResponse)?.statusCode == 200, "exactly at the limit is read")
        let size = 6 * 1024 * 1024
        for (path, chunked) in [("/v2/big", false), ("/v2/chunked", true)] {
            server.on(path, .streamed(size, chunked: chunked))
            var oversized = request
            oversized.url = server.baseURL.appendingPathComponent(String(path.dropFirst()))
            do {
                _ = try await APIClient.loadCapped(oversized, over: Environment.session, limit: limit)
                Issue.record("expected a throw for \(path)")
            } catch let error as URLError {
                #expect(error.code == .dataLengthExceedsMaximum, "\(path)")
            }
        }
        // The chunked answer is refused by the body's count, whatever the stub still pushes before it sees the cancel.
        #expect(await waitUntil(StubServer.streamGrace * 3) { self.server.streams.contains { $0.path == "/v2/big" } })
        let big = server.streams.first { $0.path == "/v2/big" }
        #expect(big?.cancelled == true && big?.delivered == 0, "a length past the limit stops at the head")
    }

    /// The iOS 14 path in a caller already cancelled: `onCancel` runs before the waiter is registered, and the
    /// load still ends, as cancelled, instead of waiting forever on a task that never starts.
    @Test func theCappedLoadInACancelledTaskEnds() async throws {
        server.on("/v2/ping", .json(["ok": true]))
        let request = URLRequest(url: server.baseURL.appendingPathComponent("v2/ping"))
        let outcome = Outcome()
        Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await APIClient.loadCapped(request, over: Environment.session, limit: 4_096)
                outcome.error = nil
            } catch {
                outcome.error = error
            }
            outcome.isDone = true
        }
        #expect(await waitUntil(5) { outcome.isDone }, "the load ends")
        #expect((outcome.error as? URLError)?.code == .cancelled, "\(String(describing: outcome.error))")
        #expect(server.requests.isEmpty, "nothing left the device")
    }

    /// A completion the delegate sees before `start` registers its waiter is kept and delivered by `start`.
    @Test func aCompletionBeforeTheWaiterIsDeliveredToIt() async throws {
        let collector = CappedResponse(limit: 4_096, allowsDowngrade: false)
        let session = URLSession(configuration: Environment.session.configuration, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: server.baseURL)
        collector.urlSession(session, task: task, didCompleteWithError: URLError(.timedOut))
        let outcome = Outcome()
        Task { @MainActor in
            do {
                _ = try await withCheckedThrowingContinuation { collector.start(task, continuation: $0) }
            } catch {
                outcome.error = error
            }
            outcome.isDone = true
        }
        #expect(await waitUntil(5) { outcome.isDone }, "start answers at once")
        #expect((outcome.error as? URLError)?.code == .timedOut, "\(String(describing: outcome.error))")
    }

    @MainActor
    private final class Outcome {
        var isDone = false
        var error: Error?
    }

    @Test func emptyBodyDecodesAsEmptyResponse() async throws {
        server.on("/v2/debug", .empty(204))
        let _: EmptyResponse = try await client.post("debug", body: Body(hello: "x"))
    }

    @Test func cancellationSurfacesAsURLErrorCancelled() async {
        server.on("/v2/ping") { _ in StubServer.Response(status: 200, body: Data("{\"ok\":true}".utf8), delay: 0.5) }
        let client = self.client
        let task = Task { () throws -> Reply in try await client.post("ping", body: Body(hello: "x")) }
        await sleepMs(50)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch let error as APIError {
            guard case .transport(let urlError) = error, urlError.code == .cancelled else { Issue.record("expected cancelled, got \(error)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func aTaskCancelledBeforePostSendsNothing() async {
        server.on("/v2/ping", .json(["ok": true]))
        let client = self.client
        // The task cancels itself and calls `post` with no await in between, so only `post`'s own check can
        // stop the request.
        let task = Task { () throws -> Reply in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.post("ping", body: Body(hello: "x"))
        }
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(server.requests.isEmpty, "nothing left the device")
    }
}
}
