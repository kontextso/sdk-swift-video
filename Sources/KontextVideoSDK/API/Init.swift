import Foundation

/// `POST /init`: 10 s, then one retry with the same request after 2 s.
enum Init {
    nonisolated(unsafe) static var retryDelay: UInt64 = 2_000_000_000

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

/// The body of `POST /init`.
struct InitRequest: Encodable, Sendable {
    struct Device: Encodable, Sendable {
        let os: OSInfo
        let hardware: HardwareInfo
    }

    /// A new UUID per call. A retry after a lost response sends the same id, so the server runs no second auction.
    let requestId: String
    let publisherToken: String
    let installId: String
    let sdk: SDKInfo
    let app: AppInfo
    let device: Device
    let attribution: AttributionIds

    @MainActor
    static func make(configuration: KontextVideo.Configuration, installId: String) -> InitRequest {
        InitRequest(
            requestId: UUID().uuidString.lowercased(),
            publisherToken: configuration.publisherToken,
            installId: installId,
            sdk: .current,
            app: .current(),
            device: Device(os: .current(), hardware: .current()),
            attribution: .current()
        )
    }
}

/// The answer to `POST /init`.
enum InitResponse: Decodable, Sendable {
    /// `reportDebug`: when true the SDK sends its debug log to `/debug`.
    case enabled(reportDebug: Bool)
    /// The server switched the SDK off. The list of reasons may grow, so it stays a string.
    case disabled(reason: String)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabledReason
        case reportDebug
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .enabled) {
            self = .enabled(reportDebug: try container.decodeIfPresent(Bool.self, forKey: .reportDebug) ?? false)
        } else {
            self = .disabled(reason: try container.decodeIfPresent(String.self, forKey: .disabledReason) ?? "unknown")
        }
    }
}
