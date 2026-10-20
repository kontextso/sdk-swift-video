/// The SDK's identity, sent as `sdk` with every server request.
struct SDKInfo: Encodable, Sendable {
    let name: String
    let version: String

    static let current = SDKInfo(name: "sdk-swift-video", version: "0.1.0")
}
