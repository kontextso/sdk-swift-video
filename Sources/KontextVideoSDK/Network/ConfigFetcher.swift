import Foundation

/// The `/config` request: the twin of `AdsFetcher`, for the one request that switches the SDK on. One attempt,
/// whatever the failure: no retry policy for now, every request is sent once. After a failure the SDK is
/// `.failed`, and the next ads request tries `/config` again (`KontextVideo.waitUntilEnabled`).
///
/// It sends and reports; `KontextVideo` acts on what it answers (the phase, the reports' switches, the user
/// agent's lookup), and owns the startup: `initialize`, the wait for `/config` and its retry, the kill switch.
@MainActor
enum ConfigFetcher {
    /// How one `/config` ended.
    enum Outcome {
        /// The server answered.
        case answered(ConfigResponse)
        /// It failed, and the failure was logged and reported.
        case failed
        /// The caller was cancelled meanwhile (`resetForTesting()`): the answer belongs to a state that was reset.
        case cancelled
    }

    /// Sends `/config` for `configuration`, once. A failure is logged and reported here: it waits in memory and
    /// leaves once a later `/config` turns the reports on.
    static func fetch(_ configuration: KontextVideo.Configuration) async -> Outcome {
        let client = APIClient(baseURL: configuration.adServerURL)
        let request = ConfigRequest.make(configuration: configuration, installId: KontextVideo.installId)
        do {
            let response = try await send(request, client: client)
            guard !Task.isCancelled else { return .cancelled }
            return .answered(response)
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            Logger.error("/config failed, no ads until it succeeds: \(error)")
            ErrorReporter.shared.report(.configFailed, stage: .config, requestId: request.requestId, failure: ErrorReport.FailedRequest(error))
            return .failed
        }
    }

    /// The POST itself, once, with no retry.
    static func send(_ request: ConfigRequest, client: APIClient) async throws -> ConfigResponse {
        try await client.post("config", body: request)
    }
}
