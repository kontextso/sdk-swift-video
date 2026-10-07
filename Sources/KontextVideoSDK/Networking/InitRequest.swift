import Foundation

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
    /// The stored session id, if any. The server decides whether it is still valid.
    let sessionId: String?
    let sdk: SDKInfo
    let app: AppInfo
    let device: Device
    let attribution: AttributionIds

    @MainActor
    static func make(configuration: Configuration, installId: String, sessionId: String?) -> InitRequest {
        InitRequest(
            requestId: UUID().uuidString.lowercased(),
            publisherToken: configuration.publisherToken,
            installId: installId,
            sessionId: sessionId,
            sdk: .current,
            app: .current(),
            device: Device(os: .current(), hardware: .current()),
            attribution: .current()
        )
    }
}
