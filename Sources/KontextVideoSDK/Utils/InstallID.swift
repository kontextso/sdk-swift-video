import Foundation

/// Persistent install ID, generated on first launch and stable across app
/// restarts (cleared only when the app is uninstalled). Sent with every
/// server request; the publisher never manages it.
enum InstallID {
    private static let defaultsKey = "so.kontext.video.installId"

    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}
