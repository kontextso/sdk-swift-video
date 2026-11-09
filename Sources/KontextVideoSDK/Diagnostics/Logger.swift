import Foundation
import os

/// Writes the SDK's messages to the device console, up to the level set in `Configuration.logLevel`, and, while
/// `/config` asks for the debug log, hands every message of every level to `DebugReporter` as the event `log`.
/// Every message is logged as public, so the console shows it unredacted: callers pass ids, events and
/// codes and URLs as they are, unredacted on purpose: the log is for development, read with the development
/// token's test ads, and the ad URLs are Kontext's own. A message is built only when the console or the
/// reporter takes it.
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

    /// Tests only: receives every message that passes the level check, with its level, as it goes to the
    /// console. Guarded by `lock`, like the level.
    nonisolated(unsafe) private static var storedSink: ((KontextVideo.Configuration.LogLevel, String) -> Void)?

    static var sink: ((KontextVideo.Configuration.LogLevel, String) -> Void)? {
        get { lock.withLock { storedSink } }
        set { lock.withLock { storedSink = newValue } }
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

    /// A line for the console only, never forwarded: `DebugReporter`'s own lines, which would otherwise make
    /// events of themselves.
    static func console(_ messageLevel: KontextVideo.Configuration.LogLevel, _ message: @autoclosure () -> String) {
        log(messageLevel, message, forward: false)
    }

    /// The level is checked first; the message is built after, and outside the lock.
    private static func log(_ messageLevel: KontextVideo.Configuration.LogLevel, _ build: () -> String, forward: Bool = true) {
        let forwards = forward && DebugReporter.forwardsConsole
        let shows = messageLevel <= level
        guard shows || forwards else { return }
        let message = build()
        if forwards { DebugReporter.forward(messageLevel, message) }
        guard shows else { return }
        sink?(messageLevel, message)
        switch messageLevel {
        case .none: break
        case .error: output.error("\(message, privacy: .public)")
        case .warning: output.warning("\(message, privacy: .public)")
        case .info: output.info("\(message, privacy: .public)")
        case .debug: output.debug("\(message, privacy: .public)")
        }
    }
}
