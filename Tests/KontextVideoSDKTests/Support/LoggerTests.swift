import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The console log: a message is built only when its level is on, URLs are reduced to scheme and host,
/// the level is settable. Serialized: the level is process-wide.
extension SerialSuites {
@Suite
@MainActor
struct LoggerTests {
    @Test func aDisabledLevelNeverBuildsItsMessage() {
        let previous = Logger.level
        defer { Logger.level = previous }
        var built = 0
        func message() -> String { built += 1; return "m" }
        Logger.level = .warning
        Logger.debug(message())
        Logger.info(message())
        #expect(built == 0, "debug and info are off at .warning")
        Logger.warning(message())
        #expect(built == 1)
        Logger.level = .none
        Logger.error(message())
        #expect(built == 1, ".none builds nothing")
    }

    @Test func anEnabledLevelBuildsItsMessageOnce() {
        let previous = Logger.level
        defer { Logger.level = previous }
        Logger.level = .debug
        var built = 0
        func message() -> String { built += 1; return "level \(Logger.level)" }   // reads the level: no lock held while building
        Logger.error(message())
        Logger.warning(message())
        Logger.info(message())
        Logger.debug(message())
        #expect(built == 4, "each message once, every level on")
    }

    @Test func aURLIsLoggedAsItsSchemeAndHostOnly() {
        #expect(Logger.describe(URL(string: "https://user:secret@brand.test:8443/p?uid=1#frag")!) == "https://brand.test", "no credentials, port, path, query or fragment")
        #expect(Logger.describe(URL(string: "https://brand.test/offer?uid=42&sig=abc")!) == "https://brand.test")
        #expect(Logger.describe(URL(string: "brandapp://offer/7?token=x")!) == "brandapp://offer")
        #expect(Logger.describe(URL(string: "mailto:viewer@example.com")!) == "mailto:")
        #expect(Logger.describe(URL(string: "javascript:alert(document.cookie)")!) == "javascript:")
        #expect(Logger.describe(URL(string: "relative/path")!) == "(no scheme)")
    }

    @Test func loggerLevelIsSettable() {
        Logger.level = .debug
        #expect(Logger.level == .debug)
        Logger.level = .none
        #expect(Logger.level == .none)
        Logger.level = .warning
    }
}
}
