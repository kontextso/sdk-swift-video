import Foundation

/// Sends the SDK's debug events to `POST /debug`, only when `/init` asked for it (`reportDebug`).
/// Events are buffered and sent in batches, at most one request per second. The body carries small
/// facts only: names, ad ids, levels, and short string/number/boolean state. Never the IFA, the IDFV,
/// the email, the user id, consent strings, request or response bodies.
@MainActor
final class DebugReporter {
    struct Event: Encodable, Sendable {
        let at: Int
        let name: String
        let adId: String?
        let level: String?
        let state: [String: Value]?
    }

    /// A string, a number or a boolean.
    enum Value: Encodable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
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
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }

    private struct Request: Encodable {
        let publisherToken: String
        let installId: String
        let sdk: SDKInfo
        let events: [Event]
    }

    static let shared = DebugReporter()
    static var interval: TimeInterval = 1

    /// Set from the `/init` response; nothing is sent while `false`.
    var isEnabled = false {
        didSet { if !isEnabled { buffer.removeAll() } }
    }

    private var buffer: [Event] = []
    private var flushTask: Task<Void, Never>?

    private init() {}

    /// Records an event; it leaves with the next batch.
    func event(_ name: String, adId: String? = nil, level: String? = nil, state: [String: Value]? = nil) {
        guard isEnabled else { return }
        buffer.append(Event(at: Int(Date().timeIntervalSince1970 * 1000), name: name, adId: adId, level: level, state: state))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            self?.flushTask = nil
            await self?.flush()
        }
    }

    private func flush() async {
        guard isEnabled, !buffer.isEmpty, let configuration = KontextVideo.shared.configuration else { return }
        let events = buffer
        buffer.removeAll()
        let request = Request(publisherToken: configuration.publisherToken, installId: KontextVideo.installId, sdk: SDKInfo(), events: events)
        let client = APIClient(baseURL: configuration.adServerURL)
        do {
            let _: EmptyResponse = try await client.post("debug", body: request)
        } catch {
            // Debug reporting never affects the SDK; a lost batch is lost.
            Logger.debug("debug batch of \(events.count) not delivered: \(error)")
        }
    }
}

/// A `204` with no body.
struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}
