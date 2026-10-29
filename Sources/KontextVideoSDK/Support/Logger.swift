import Foundation
import os

/// Writes the SDK's messages to the device console, up to the level set in `Configuration.logLevel`.
/// Every message is logged as public, so the console shows it unredacted: callers pass ids, events and
/// codes, never anything private. A URL from outside goes through `Logger.describe(_:)`, which keeps only
/// its scheme and host. A message is built only when its level is on.
enum Logger {
    private static let output = os.Logger(subsystem: "so.kontext.video", category: "KontextVideoSDK")
    private static let lock = NSLock()
    /// Read from any thread. `nonisolated(unsafe)` only turns off the compiler's check; `lock`, around every
    /// access, is what makes it safe.
    nonisolated(unsafe) private static var storedLevel: KontextVideo.Configuration.LogLevel = .warning

    static var level: KontextVideo.Configuration.LogLevel {
        get { lock.withLock { storedLevel } }
        set { lock.withLock { storedLevel = newValue } }
    }

    static func error(_ message: @autoclosure () -> String) {
        log(.error, message)
    }

    static func warning(_ message: @autoclosure () -> String) {
        log(.warning, message)
    }

    static func info(_ message: @autoclosure () -> String) {
        log(.info, message)
    }

    static func debug(_ message: @autoclosure () -> String) {
        log(.debug, message)
    }

    /// A URL from outside (a click-through, a refused navigation) as the log may show it: scheme and host,
    /// never the path, query or anything a host-less URL carries (`mailto:` addresses, `javascript:` code).
    static func describe(_ url: URL) -> String {
        let scheme = url.scheme.map { "\($0):" } ?? "(no scheme)"
        return url.host.map { "\(scheme)//\($0)" } ?? scheme
    }

    /// The level is checked first; the message is built after, and outside the lock.
    private static func log(_ messageLevel: KontextVideo.Configuration.LogLevel, _ build: () -> String) {
        guard messageLevel <= level else { return }
        let message = build()
        switch messageLevel {
        case .none: break
        case .error: output.error("\(message, privacy: .public)")
        case .warning: output.warning("\(message, privacy: .public)")
        case .info: output.info("\(message, privacy: .public)")
        case .debug: output.debug("\(message, privacy: .public)")
        }
    }
}
