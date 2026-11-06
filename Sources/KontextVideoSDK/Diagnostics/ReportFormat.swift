import Foundation

/// How the SDK's reports write their fields, shared by `ErrorReporter` and `DebugReporter` so neither reaches into
/// the other: a state value as JSON, the timestamp, the cap on every string field the reporters keep.
enum ReportFormat {
    /// A string, a number or a boolean: a debug event's state, and an error report's history.
    enum Value: Encodable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
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

    /// UTF-8 bytes kept of every string field: ids, `detail`, the underlying error's domain, history names
    /// and values, a debug event's name, ad id and state values. Bytes, not characters: one character can carry
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
    static func timestamp() -> String {
        formatter.string(from: Date())
    }

    /// `ISO8601DateFormatter.string(from:)` is documented thread-safe.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
