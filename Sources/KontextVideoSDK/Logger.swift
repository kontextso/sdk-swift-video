import Foundation
import os

/// Writes the SDK's messages to the device console, up to the level set in `Configuration.logLevel`.
enum Logger {
    private static let output = os.Logger(subsystem: "so.kontext.video", category: "KontextVideoSDK")
    private static let lock = NSLock()
    private static var storedLevel: KontextVideo.Configuration.LogLevel = .warning

    static var level: KontextVideo.Configuration.LogLevel {
        get { lock.withLock { storedLevel } }
        set { lock.withLock { storedLevel = newValue } }
    }

    static func error(_ message: String) {
        log(.error, message)
    }

    static func warning(_ message: String) {
        log(.warning, message)
    }

    static func info(_ message: String) {
        log(.info, message)
    }

    static func debug(_ message: String) {
        log(.debug, message)
    }

    private static func log(_ messageLevel: KontextVideo.Configuration.LogLevel, _ message: String) {
        guard messageLevel <= level else { return }
        switch messageLevel {
        case .none: break
        case .error: output.error("\(message, privacy: .public)")
        case .warning: output.warning("\(message, privacy: .public)")
        case .info: output.info("\(message, privacy: .public)")
        case .debug: output.debug("\(message, privacy: .public)")
        }
    }
}
