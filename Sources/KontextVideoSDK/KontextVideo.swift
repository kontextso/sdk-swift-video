import Foundation
import KontextKit

/// Entry point of the Kontext Video SDK.
public enum KontextVideo {
    public static let version = SDKInfo.current.version

    /// Identifies this installation of the app. Created on first use and kept until the app is uninstalled.
    public static var installId: String {
        InstallIdProvider.getOrCreate()
    }
}
