import Foundation

/// Fires an ad's `tracking` entries: each one once, when its moment happens, with the macros substituted:
/// the IAB's (`[CACHEBUSTING]`, `[TIMESTAMP]`, `[MEDIAPLAYHEAD]` and its deprecated twin `[CONTENTPLAYHEAD]`,
/// `[ADPLAYHEAD]`, `[ERRORCODE]`) and our own, prefixed `KONTEXT_` so they never collide with the IAB registry
/// (`[REASON]` there is an integer for verification pixels). A macro the SDK does not know stays in place.
/// The page never fires a beacon; the SDK fires every one. No retries: a beacon that did not leave is lost,
/// as in every ad SDK.
@MainActor
final class Tracker {
    /// Milliseconds into the ad video, as the page last reported it; `[ADPLAYHEAD]`.
    var adPlayhead = 0
    /// Content time in seconds at the moment of firing; `[MEDIAPLAYHEAD]` and `[CONTENTPLAYHEAD]`.
    var contentPlayhead: () -> TimeInterval = { 0 }

    private let adId: String
    private let entries: [AdPayload.TrackingEvent]
    private var fired: Set<Int> = []
    private let session: URLSession

    init(adId: String, entries: [AdPayload.TrackingEvent]) {
        self.adId = adId
        self.entries = entries
        session = Environment.session
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
            fired.insert(index)
            guard let url = URL(string: substitute(entry.url, errorCode: errorCode, fireId: fireId, viewDurationMs: viewDurationMs, notUsed: notUsed)) else {
                Logger.warning("ad \(adId.prefix(8)): \(event) beacon has an invalid URL")
                continue
            }
            send(url, event: event, part: part)
        }
        return fireId
    }

    /// The click-through with the beacon macros substituted, `[KONTEXT_FIREID]` with the click's own fire id:
    /// a redirect URL and the `click` beacon then arrive as one occurrence.
    func clickThrough(_ url: URL, fireId: String) -> URL {
        URL(string: substitute(url.absoluteString, errorCode: nil, fireId: fireId, viewDurationMs: nil, notUsed: nil)) ?? url
    }

    private func substitute(_ template: String, errorCode: Int?, fireId: String, viewDurationMs: Int?, notUsed: NotUsed?) -> String {
        template
            .replacingOccurrences(of: "[CACHEBUSTING]", with: String(format: "%08d", Int.random(in: 0..<100_000_000)))
            .replacingOccurrences(of: "[TIMESTAMP]", with: Self.encode(Self.timestamp.string(from: Date())))
            .replacingOccurrences(of: "[MEDIAPLAYHEAD]", with: Self.encode(Self.playhead(seconds: contentPlayhead())))
            .replacingOccurrences(of: "[CONTENTPLAYHEAD]", with: Self.encode(Self.playhead(seconds: contentPlayhead())))
            .replacingOccurrences(of: "[ADPLAYHEAD]", with: Self.encode(Self.playhead(seconds: TimeInterval(adPlayhead) / 1000)))
            .replacingOccurrences(of: "[ERRORCODE]", with: errorCode.map(String.init) ?? "")
            .replacingOccurrences(of: "[KONTEXT_FIREID]", with: fireId)
            .replacingOccurrences(of: "[KONTEXT_VIEWDURATION]", with: viewDurationMs.map(String.init) ?? "")
            .replacingOccurrences(of: "[KONTEXT_REASON]", with: notUsed?.reason ?? "")
            .replacingOccurrences(of: "[KONTEXT_WINNINGPRICE]", with: notUsed?.winningPrice.map { String($0) } ?? "")
            .replacingOccurrences(of: "[KONTEXT_WINNER]", with: Self.encode(notUsed?.winner ?? ""))
            // A macro the SDK does not know stays, encoded: a bare `[` makes Foundation re-encode the whole
            // URL, and every `%3A` above would become `%253A`.
            .replacingOccurrences(of: "[", with: "%5B")
            .replacingOccurrences(of: "]", with: "%5D")
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

    // VAST 4 macro formats: `YYYY-MM-DDTHH:MM:SS.mmm±HH:MM` in the device's zone, and HH:MM:SS.mmm for playheads.

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private static func playhead(seconds: TimeInterval) -> String {
        // Whole milliseconds first: splitting the Double would lose one (9.806 is 9.80599… in binary).
        let totalMs = Int((max(0, seconds) * 1000).rounded())
        let hours = totalMs / 3_600_000
        let minutes = totalMs / 60_000 % 60
        let secs = totalMs / 1000 % 60
        let millis = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }
}

extension Tracker {
    /// Why the SDK did not use a bid, for the `notUsed` beacon: the server closes the bid with this reason.
    struct NotUsed: Equatable {
        /// `notUsed` or `outbid` (the app's `reject`), `destroyed` (`VideoAds.destroy()`).
        let reason: String
        /// What won the publisher's own auction, when the app said so: the price and the network.
        let winningPrice: Double?
        let winner: String?

        static let destroyed = NotUsed(reason: "destroyed", winningPrice: nil, winner: nil)

        init(reason: String, winningPrice: Double?, winner: String?) {
            self.reason = reason
            self.winningPrice = winningPrice
            self.winner = winner
        }

        init(_ rejection: VideoAd.RejectReason) {
            switch rejection {
            case .notUsed: self.init(reason: "notUsed", winningPrice: nil, winner: nil)
            case .outbid(let price, let winner): self.init(reason: "outbid", winningPrice: price, winner: winner)
            }
        }
    }
}

private extension CharacterSet {
    /// Everything a query value may contain unescaped; `:` and `+` are escaped so playheads and offsets survive.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: ":+&=")
        return set
    }()
}
