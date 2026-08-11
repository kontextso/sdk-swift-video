/// Compile-time SDK identity (name + platform + version) sent with every
/// server request.
///
/// Release process: bump `sdkVersion` together with the podspec's
/// `s.version` and the release tag — they're expected to agree.
struct SDKInfo: Sendable, Encodable {
    let name: String
    let platform: String
    let version: String

    /// Current SDK version in Major.Minor.Patch format.
    static let sdkVersion = "0.1.0"

    static let sdkName = "sdk-swift-video"

    static let sdkPlatform = "ios"

    static let current = SDKInfo(
        name: sdkName,
        platform: sdkPlatform,
        version: sdkVersion
    )
}
