/// The SDK's identity, sent as the `sdk` object with every server request.
struct SDKInfo: Encodable, Sendable {
    /// As the server knows this SDK; the Kotlin SDK is `sdk-kotlin-video`.
    static let name = "sdk-swift-video"
    /// The one place the version is written. The podspec reads it from this line, and CI refuses a release
    /// tag that does not match it; see RELEASING.md.
    static let version = "0.1.0"

    private enum CodingKeys: String, CodingKey {
        case name, version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.name, forKey: .name)
        try container.encode(Self.version, forKey: .version)
    }
}
