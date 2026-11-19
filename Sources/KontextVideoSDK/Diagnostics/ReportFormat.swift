import Foundation

/// How the SDK's reports write their fields, shared by `ErrorReporter` and `DebugReporter` so neither reaches into
/// the other: a property value as JSON, the timestamp, the cap on the string fields the reporters keep, the OS as
/// both envelopes carry it.
enum ReportFormat {
    /// The `os` object of a batch: the name as the server knows it, and the version.
    struct OS: Encodable, Sendable {
        let name: String
        let version: String
    }

    /// The device's OS for a batch's envelope.
    @MainActor
    static func os() -> OS {
        let info = OSInfo.current()
        return OS(name: info.name.rawValue, version: info.version)
    }

    /// A string, a number or a boolean: a debug event's properties, and so an error report's history.
    enum Value: Encodable, Sendable, Equatable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
        case string(String)
        case number(Double)
        case bool(Bool)

        init(stringLiteral value: String) { self = .string(value) }
        init(integerLiteral value: Int) { self = .number(Double(value)) }
        init(booleanLiteral value: Bool) { self = .bool(value) }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            // JSON has no NaN or infinity, and the encoder throws on them: one such value must not cost the reports
            // batched with it. Written as text (`"nan"`), as `description` reads it.
            case .number(let value) where !value.isFinite: try container.encode(String(value))
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }

        var description: String {
            switch self {
            case .string(let value): return value
            case .number(let value): return Int(exactly: value).map(String.init) ?? String(value)
            case .bool(let value): return String(value)
            }
        }
    }

    /// UTF-8 bytes kept of a report's string fields: ids, `detail`, the cause's domain, a debug event's name, bid
    /// id and property values; not a console line forwarded as `log`. Bytes, not characters: one character can carry
    /// any number of combining marks. Ids are about 36; a server sending far longer ones must not grow the buffers
    /// the SDK holds for the app's life.
    static let maxFieldLength = 64

    /// `text` cut to `limit` UTF-8 bytes, at a Unicode scalar boundary so it stays valid text.
    static func capped(_ text: String, to limit: Int = maxFieldLength) -> String {
        guard text.utf8.count > limit else { return text }
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            guard bytes + size <= limit else { break }
            scalars.append(scalar)
            bytes += size
        }
        return String(scalars)
    }

    /// `2026-10-21T18:00:00.482Z`: device time, ISO 8601 with milliseconds in UTC, as Kontext's APIs write
    /// wall-clock time.
    static func timestamp(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    /// `ISO8601DateFormatter.string(from:)` is documented thread-safe.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
