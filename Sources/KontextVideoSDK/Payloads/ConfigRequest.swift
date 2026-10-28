import Foundation

/// The body of `POST /config`.
struct ConfigRequest: Encodable, Sendable {
    struct Device: Encodable, Sendable {
        let os: OSInfo
        let hardware: HardwareInfo
    }

    /// A new UUID per request, a retry included: it traces one request through the device log, the debug
    /// events and the server's log. Not a replay key; `/config` creates nothing, so a retry is answered fresh.
    let requestId: String
    let publisherToken: String
    let installId: String
    let sdk: SDKInfo
    let app: AppInfo
    let device: Device
    let attribution: AttributionIds

    /// The same request under a new id, for the retry: the device facts stay as they were read.
    func retry() -> ConfigRequest {
        ConfigRequest(requestId: UUID().uuidString.lowercased(), publisherToken: publisherToken, installId: installId,
                      sdk: sdk, app: app, device: device, attribution: attribution)
    }

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
