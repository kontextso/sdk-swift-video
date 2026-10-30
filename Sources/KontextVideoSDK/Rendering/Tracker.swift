import Foundation

/// Fires an ad's `tracking` entries when their moment happens, once each except the events that repeat
/// (`repeatable`), with the macros substituted: the IAB's (`[CACHEBUSTING]`, `[TIMESTAMP]`, `[MEDIAPLAYHEAD]`
/// and its deprecated twin `[CONTENTPLAYHEAD]`, `[ADPLAYHEAD]`, `[ERRORCODE]`) and our own, prefixed `KONTEXT_`
/// so they never collide with the IAB registry (`[REASON]` there is an integer for verification pixels). A
/// macro the SDK does not know stays in place. The page never fires a beacon; the SDK fires every one. No
/// retries: a beacon that did not leave is lost, as in every ad SDK.
@MainActor
final class Tracker {
    /// Milliseconds into the ad video, as the page last reported it; `[ADPLAYHEAD]`.
    var adPlayhead = 0
    /// Content time in seconds; `[MEDIAPLAYHEAD]` and `[CONTENTPLAYHEAD]`. The app's player behind it is app
    /// code, so the ad reads it once before an operation (`frozenContentPlayhead`) rather than inside a beacon.
    var contentPlayhead: () -> TimeInterval = { 0 }
    /// The content playhead read before the operation now running; every beacon of it uses this value and
    /// calls no app code. `nil` outside an operation: a beacon then reads `contentPlayhead` itself.
    var frozenContentPlayhead: TimeInterval?
    /// The last value the app's player gave; what an operation started while it is read uses.
    var lastContentPlayhead: TimeInterval = 0
    /// Whether any URL asks for the content playhead; when none does, nobody reads it.
    let readsContentPlayhead: Bool

    /// Events that fire every time they happen, as VAST players do (a second click is a second click, every
    /// pause counts); each occurrence gets its own fire id. Everything else fires once per entry.
    static let repeatable: Set<String> = ["click", "pause", "resume", "mute", "unmute"]

    private let adId: String
    private let entries: [AdPayload.TrackingEvent]
    private var fired: Set<Int> = []
    private let session: URLSession

    init(adId: String, entries: [AdPayload.TrackingEvent]) {
        self.adId = adId
        self.entries = entries
        session = Environment.session
        readsContentPlayhead = entries.contains { Self.asksForContentPlayhead($0.url) }
    }

    /// Fires every entry named `event` for `part` (`nil` is the main creative) that has not fired yet.
    /// `offset` selects a `progress` entry; `errorCode` fills `[ERRORCODE]`, `notUsed` fills `[KONTEXT_REASON]`,
    /// `[KONTEXT_WINNINGPRICE]` and `[KONTEXT_WINNER]`. Returns the occurrence's fire id, for a click-through
    /// that must carry the same one.
    @discardableResult
    func fire(_ event: String, part: String? = nil, offset: Int? = nil, errorCode: Int? = nil, viewDurationMs: Int? = nil, notUsed: NotUsed? = nil) -> String {
        // One fire id per event occurrence, shared by every URL of it: the server dedupes on
        // (adId, event, fid), so a retry one day, or a duplicate for any reason, counts once.
        let fireId = UUID().uuidString.lowercased()
        for (index, entry) in entries.enumerated() where !fired.contains(index) {
            guard entry.event == event, entry.part == part else { continue }
            if let offset, entry.offset != offset { continue }
            if !Self.repeatable.contains(event) { fired.insert(index) }
            guard let url = URL(string: substitute(entry.url, errorCode: errorCode, fireId: fireId, viewDurationMs: viewDurationMs, notUsed: notUsed)) else {
                Logger.warning("ad \(adId.prefix(8)): \(event) beacon has an invalid URL")
                continue
            }
            send(url, event: event, part: part)
        }
        return fireId
    }

    private func send(_ url: URL, event: String, part: String?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let label = part.map { "\(event) (\($0))" } ?? event
        Logger.debug("ad \(adId.prefix(8)): beacon \(label)")
        let id = adId
        session.dataTask(with: request) { _, response, error in
            if let error {
                Logger.warning("ad \(id.prefix(8)): \(label) beacon failed, \(error.localizedDescription)")
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                Logger.warning("ad \(id.prefix(8)): \(label) beacon answered \(status)")
            }
        }.resume()
    }

    /// Fires every `progress` entry the ad video has passed (`offset` at or below `playheadMs`) and not fired
    /// yet, each as its own occurrence. The page reports the checkpoint it saw; the SDK decides from the
    /// playhead, as VAST players do, so a checkpoint the page skipped (a stall, a seek) or rounded differently
    /// still fires.
    func fireProgress(upTo playheadMs: Int) {
        // Each checkpoint not fired yet, once, in order: a fired one is skipped instead of scanned again, and
        // entries sharing an offset fire as one occurrence with one fire id.
        let due = Set(entries.indices.compactMap { index -> Int? in
            let entry = entries[index]
            guard entry.event == "progress", !fired.contains(index), let offset = entry.offset, offset <= playheadMs else { return nil }
            return offset
        })
        for offset in due.sorted() {
            fire("progress", offset: offset)
        }
    }

    /// The click-through with the beacon macros substituted, `[KONTEXT_FIREID]` with the click's own fire id:
    /// a redirect URL and the `click` beacon then arrive as one occurrence.
    func clickThrough(_ url: URL, fireId: String) -> URL {
        URL(string: substitute(url.absoluteString, errorCode: nil, fireId: fireId, viewDurationMs: nil, notUsed: nil)) ?? url
    }

    private func substitute(_ template: String, errorCode: Int?, fireId: String, viewDurationMs: Int?, notUsed: NotUsed?) -> String {
        // A macro may arrive with its brackets encoded, one or both (a click-through parsed into a `URL`):
        // normalized first, so detection and substitution see the same string. The end re-encodes whatever
        // is left, so a bracket that was never a macro comes out as it went in.
        let normalized = template
            .replacingOccurrences(of: "%5B", with: "[", options: .caseInsensitive)
            .replacingOccurrences(of: "%5D", with: "]", options: .caseInsensitive)
        // The content playhead read once, and only when a URL asks for it: its two names are one moment.
        let content = Self.asksForContentPlayhead(normalized)
            ? Self.encode(Self.playhead(seconds: frozenContentPlayhead ?? contentPlayhead())) : ""
        return normalized
            .replacingOccurrences(of: "[CACHEBUSTING]", with: String(format: "%08d", Int.random(in: 0..<100_000_000)))
            .replacingOccurrences(of: "[TIMESTAMP]", with: Self.encode(Self.timestamp.string(from: Date())))
            .replacingOccurrences(of: "[MEDIAPLAYHEAD]", with: content)
            .replacingOccurrences(of: "[CONTENTPLAYHEAD]", with: content)
            .replacingOccurrences(of: "[ADPLAYHEAD]", with: Self.encode(Self.playhead(seconds: TimeInterval(adPlayhead) / 1000)))
            .replacingOccurrences(of: "[ERRORCODE]", with: errorCode.map(String.init) ?? "")
            .replacingOccurrences(of: "[KONTEXT_FIREID]", with: fireId)
            .replacingOccurrences(of: "[KONTEXT_VIEWDURATION]", with: viewDurationMs.map(String.init) ?? "")
            .replacingOccurrences(of: "[KONTEXT_REASON]", with: notUsed?.reason ?? "")
            .replacingOccurrences(of: "[KONTEXT_WINNINGPRICE]", with: Self.encode(notUsed?.winningPrice.map { String($0) } ?? ""))
            .replacingOccurrences(of: "[KONTEXT_WINNER]", with: Self.encode(notUsed?.winner ?? ""))
            // A macro the SDK does not know stays, encoded: a bare `[` makes Foundation re-encode the whole
            // URL, and every `%3A` above would become `%253A`.
            .replacingOccurrences(of: "[", with: "%5B")
            .replacingOccurrences(of: "]", with: "%5D")
    }

    /// Either name of the content playhead, its brackets encoded or not.
    static func asksForContentPlayhead(_ template: String) -> Bool {
        let normalized = template
            .replacingOccurrences(of: "%5B", with: "[", options: .caseInsensitive)
            .replacingOccurrences(of: "%5D", with: "]", options: .caseInsensitive)
        return normalized.contains("[MEDIAPLAYHEAD]") || normalized.contains("[CONTENTPLAYHEAD]")
    }

    /// `[TIMESTAMP]`: `YYYY-MM-DDTHH:MM:SS.mmm±HH:MM` in the device's zone.
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    /// Playheads beyond this (ten years, the same cap as the content playhead) are nonsense and clamped:
    /// a value near `Int.max` would trap the `Int` conversion below.
    static let maxPlayhead: TimeInterval = 315_360_000

    /// `[MEDIAPLAYHEAD]`, `[ADPLAYHEAD]`: `HH:MM:SS.mmm`.
    static func playhead(seconds: TimeInterval) -> String {
        let seconds = seconds.isFinite ? min(max(0, seconds), maxPlayhead) : 0
        // Whole milliseconds first: splitting the Double would lose one (9.806 is 9.80599… in binary).
        let totalMs = Int((seconds * 1000).rounded())
        let hours = totalMs / 3_600_000
        let minutes = totalMs / 60_000 % 60
        let secs = totalMs / 1000 % 60
        let millis = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    /// A value inside one query parameter: only RFC 3986's unreserved characters stay, so `:` in a playhead,
    /// `+` in a price and `;`, `/` or `?` in a winner's name are no parser's delimiter.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }
}

extension Tracker {
    /// Why the SDK did not use a bid, for the `notUsed` beacon: the server closes the bid with this reason.
    enum NotUsed: Equatable {
        /// The app's `reject()`: it did not use the ad.
        case notUsed
        /// The app's `reject(.outbid)`: another network won its auction, at this price, if it said so.
        case outbid(winningPrice: Double?, winner: String?)
        /// `VideoAds.destroy()` with the ad still held.
        case destroyed

        init(_ rejection: VideoAd.RejectReason) {
            switch rejection {
            case .notUsed: self = .notUsed
            case .outbid(let price, let winner): self = .outbid(winningPrice: price, winner: winner)
            }
        }

        /// `[KONTEXT_REASON]`.
        var reason: String {
            switch self {
            case .notUsed: return "notUsed"
            case .outbid: return "outbid"
            case .destroyed: return "destroyed"
            }
        }

        /// `[KONTEXT_WINNINGPRICE]` and `[KONTEXT_WINNER]`: set only by `outbid`.
        var winningPrice: Double? {
            if case .outbid(let price, _) = self { return price }
            return nil
        }

        var winner: String? {
            if case .outbid(_, let winner) = self { return winner }
            return nil
        }
    }
}

private extension CharacterSet {
    /// RFC 3986 unreserved: letters, digits, `-._~`.
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
