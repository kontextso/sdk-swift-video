import Foundation

/// `POST /init`: 10 s, then one retry with the same request after 2 s.
enum Init {
    static let retryDelay: UInt64 = 2_000_000_000

    static func send(_ request: InitRequest, client: APIClient) async throws -> InitResponse {
        do {
            return try await client.post("init", body: request)
        } catch let error as APIError where error.isRetryable {
            Logger.warning("/init failed (\(error)); retrying in 2 s")
            try await Task.sleep(nanoseconds: retryDelay)
            return try await client.post("init", body: request)
        }
    }
}
