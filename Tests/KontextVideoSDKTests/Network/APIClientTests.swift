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
            #expect(error.isRetryable == false)
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
                #expect(error.isRetryable == (status >= 500), "\(name)")
            } catch {
                Issue.record("unexpected \(error) for \(name)")
            }
        }
    }

    @Test func serverErrorsAndRateLimitsAreRetryable() async {
        for status in [500, 503, 429] {
            server.on("/v2/ping", .empty(status))
            do {
                let _: Reply = try await client.post("ping", body: Body(hello: "x"))
                Issue.record("expected a throw for \(status)")
            } catch let error as APIError {
                guard case .http(let got, let errors) = error else { Issue.record("expected http"); return }
                #expect(got == status)
                #expect(errors.isEmpty, "no body, no parsed errors")
                #expect(error.isRetryable)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func transportFailureIsRetryable() async {
        server.on("/v2/ping", .failure(.notConnectedToInternet))
        do {
            let _: Reply = try await client.post("ping", body: Body(hello: "x"))
            Issue.record("expected a throw")
        } catch let error as APIError {
            guard case .transport(let urlError) = error else { Issue.record("expected transport"); return }
            #expect(urlError.code == .notConnectedToInternet)
            #expect(error.isRetryable)
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
            #expect(error.isRetryable == false)
        } catch {
            Issue.record("unexpected \(error)")
        }
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
            #expect(error.isRetryable == false, "whoever cancelled it does not want it sent again")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func aTaskCancelledBeforePostSendsNothing() async {
        server.on("/v2/ping", .json(["ok": true]))
        let client = self.client
        let task = Task { () throws -> Reply in
            try await Task.sleep(nanoseconds: 50_000_000)
            return try await client.post("ping", body: Body(hello: "x"))
        }
        task.cancel()
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
