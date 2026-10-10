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
