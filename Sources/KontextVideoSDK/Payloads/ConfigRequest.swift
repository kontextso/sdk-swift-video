import Foundation

/// The body of `POST /config`.
struct ConfigRequest: Encodable, Sendable {
    struct Device: Encodable, Sendable {
        let os: OSInfo
        let hardware: HardwareInfo
    }

    /// A new UUID per request: it traces one request through the device log, the debug events, the error
    /// reports and the server's log. Not a replay key; `/config` creates nothing.
    let requestId: String
    let publisherToken: String
    let installId: String
    let sdk: SDKInfo
    let app: AppInfo
    let device: Device
    let attribution: AttributionIds

    @MainActor
    static func make(configuration: KontextVideo.Configuration, installId: String) -> ConfigRequest {
        ConfigRequest(
            requestId: UUID().uuidString.lowercased(),
            publisherToken: configuration.publisherToken,
            installId: installId,
            sdk: SDKInfo(),
            app: .current(),
            device: Device(os: .current(), hardware: .current()),
            attribution: .current()
        )
    }
}
