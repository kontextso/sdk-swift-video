/// The last `historyLength` debug events, kept on the device for the history an error report carries, whether or
/// not the server asked for the debug log; no sending. `DebugReporter` records into it, `ErrorReport` reads
/// `recent()`. An entry is the event as it would go to `/debug`, so the two read the same.
@MainActor
enum EventHistory {
    static let historyLength = 30

    private static var events: [DebugReporter.Event] = []

    /// Keeps one event; the oldest goes past `historyLength`.
    static func record(_ event: DebugReporter.Event) {
        events.append(event)
        if events.count > historyLength { events.removeFirst(events.count - historyLength) }
    }

    /// The recent events, oldest first, as kept.
    static func recent() -> [DebugReporter.Event] { events }

    /// Forgets every event. Tests, and `DebugReporter.resetForTesting()`.
    static func clear() {
        events.removeAll()
    }
}
