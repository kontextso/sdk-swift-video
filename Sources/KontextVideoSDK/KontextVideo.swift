import Foundation
import KontextKit

/// Entry point of the Kontext Video SDK.
@MainActor
public final class KontextVideo {
    public static let shared = KontextVideo()

    public nonisolated static let version = SDKInfo.current.version

    /// Identifies this installation of the app. Created on first use and kept until the app is uninstalled.
    public static var installId: String {
        InstallIdProvider.getOrCreate()
    }

    /// The configuration the SDK was initialised with, or `nil` before `initialize(with:)`.
    public private(set) var configuration: Configuration?

    public var isInitialized: Bool {
        configuration != nil
    }

    private init() {}

    /// Starts the SDK. Call it once, at app launch; later calls are ignored.
    public func initialize(with configuration: Configuration) {
        guard !isInitialized else { return }
        self.configuration = configuration
    }
}
