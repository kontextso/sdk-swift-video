import Foundation

/// Fires an ad's `tracking` entries when their moment happens, once each except the events that repeat
/// (`repeatable`), with the macros substituted (`TrackingMacros`). The page never fires a beacon; the SDK fires
/// every one. No retries: a beacon that did not leave is lost.
@MainActor
final class Tracker {
    /// Milliseconds into the ad video, as the page last reported it; `[ADPLAYHEAD]`.
    var adPlayhead = 0
    /// Content time in seconds; `[MEDIAPLAYHEAD]` and `[CONTENTPLAYHEAD]`. The app's player behind it is app
    /// code, so the ad reads it once before an operation (`frozenContentPlayhead`) rather than inside a beacon.
    var contentPlayhead: () -> TimeInterval = { 0 }
    /// The content playhead read before the operation now running; every beacon of it uses this value and
    /// calls no app code. `nil` outside an operation: a beacon then reads `contentPlayhead` itself.
    private var frozenContentPlayhead: TimeInterval?
    /// The last value the app's player gave; what an operation started while it is read uses.
    private var lastContentPlayhead: TimeInterval = 0
    /// Whether any URL asks for the content playhead; when none does, nobody reads it.
    let readsContentPlayhead: Bool

    /// Events that fire every time they happen, as VAST players do (a second click is a second click, every
    /// pause counts); each occurrence gets its own fire id. Everything else fires once per entry.
    static let repeatable: Set<String> = ["click", "pause", "resume", "mute", "unmute"]

    private let bidId: String
    private let entries: [AdPayload.TrackingEvent]
    /// The entries' indices by event, in the answer's order: a beacon looks at its own entries only. An answer may
    /// carry thousands of progress checkpoints, and a catch-up over all of them must not rescan every entry per
    /// checkpoint on the main thread.
    private let indicesByEvent: [String: [Int]]
    /// The progress entries' indices by offset, and those offsets ascending.
    private let progressByOffset: [Int: [Int]]
    private let progressOffsets: [Int]
    private var fired: Set<Int> = []
    /// `video.start` was recorded. Mute, unmute and skip may come before it (the viewer's); they fire their own
    /// beacons, but a video that never started passed no checkpoint.
    private var hasVideoStarted = false
    private let session: URLSession

    init(adId: String, entries: [AdPayload.TrackingEvent]) {
        self.adId = adId
        self.entries = entries
        indicesByEvent = Dictionary(grouping: entries.indices, by: { entries[$0].event })
        let progress = entries.indices.filter { entries[$0].event == "progress" && entries[$0].offset != nil }
        progressByOffset = Dictionary(grouping: progress, by: { entries[$0].offset ?? 0 })
        progressOffsets = progressByOffset.keys.sorted()
        session = Environment.session
        readsContentPlayhead = entries.contains { TrackingMacros.asksForContentPlayhead($0.url) }
    }

    /// Runs `work` with the content playhead read once, before it. The app's player (`currentTime`) is the one
    /// piece of app code a beacon calls; read here it sees the ad before the operation changes anything, and
    /// every beacon inside uses that value. Nested calls share the outer read; nothing is read when no URL
    /// asks for it (`urls`: the operation's, a click's destinations). While the player is read, the last value
    /// is the frozen one: an operation it starts reads nothing more, so a player that ends the ad cannot recurse.
    @discardableResult
    func withContentPlayhead<T>(alsoFor urls: [URL] = [], _ work: () throws -> T) rethrows -> T {
        let asked = readsContentPlayhead || urls.contains { TrackingMacros.asksForContentPlayhead($0.absoluteString) }
        guard frozenContentPlayhead == nil, asked else { return try work() }
        frozenContentPlayhead = lastContentPlayhead
        defer { frozenContentPlayhead = nil }
        let playhead = contentPlayhead()
        lastContentPlayhead = playhead
        frozenContentPlayhead = playhead
        return try work()
    }

    /// The beacons of one page event, and the ad playhead it carries: `loaded`, `error` with its code, `iconClick`
    /// for an AdChoices open, a video moment, progress checkpoints the page passed without reporting them, `skip`,
    /// and at `complete` the end card's `creativeView`. What the ad does about the event (its state, the delegate,
    /// its end) is the ad's, around this call. Not here: a click's beacon, which shares its fire id with the
    /// click-through (`VideoAd.click`), and a close's, which depends on how the close ends the ad. It takes a
    /// `FrameEvent` because the beacons are named after the page's events (the VAST names).
    func record(_ event: FrameEvent) {
        switch event {
        case .loaded:
            fire("loaded")
        case .error(let code):
            fire("error", errorCode: code)
        case .open(_, let purpose):
            if purpose == "adChoices" { fire("iconClick") }
        case .skip(let playhead):
            adPlayhead = playhead
            // Checkpoints the video passed before the skip that the page never reported, then the skip.
            catchUpProgress(upTo: playhead)
            fire("skip")
        case .video(let moment, let playhead):
            adPlayhead = playhead
            if moment == .start { hasVideoStarted = true }
            fire(moment.rawValue)
            catchUpProgress(upTo: playhead)
        case .progress(let offset, let playhead):
            adPlayhead = playhead
            catchUpProgress(upTo: max(offset, playhead))
        case .complete(let playhead):
            adPlayhead = playhead
            // Checkpoints before the end that the page never reported, then the end itself.
            catchUpProgress(upTo: playhead)
            fire("complete")
            // The end card, when there is one, becomes visible now.
            fire("creativeView", part: "endCard")
        case .click, .close:
            break
        }
    }

    /// Fires every entry named `event` for `part` (`nil` is the main creative) that has not fired yet.
    /// `offset` selects a `progress` entry; `errorCode` fills `[ERRORCODE]`, `notUsed` fills `[KONTEXT_REASON]`,
    /// `[KONTEXT_WINNINGPRICE]` and `[KONTEXT_WINNER]`. Returns the occurrence's fire id, for a click-through
    /// that must carry the same one.
    @discardableResult
    func fire(_ event: String, part: String? = nil, offset: Int? = nil, errorCode: Int? = nil, viewDurationMs: Int? = nil, notUsed: NotUsed? = nil) -> String {
        // One fire id per event occurrence, shared by every URL of it: the server dedupes on
        // (bidId, event, fid), so a retry one day, or a duplicate for any reason, counts once.
        let fireID = UUID().uuidString.lowercased()
        let candidates = event == "progress" && offset != nil ? progressByOffset[offset ?? 0] ?? [] : indicesByEvent[event] ?? []
        for index in candidates where !fired.contains(index) {
            let entry = entries[index]
            guard entry.part == part else { continue }
            if let offset, entry.offset != offset { continue }
            if !Self.repeatable.contains(event) { fired.insert(index) }
            guard let url = URL(string: substitute(entry.url, errorCode: errorCode, fireID: fireID, viewDurationMs: viewDurationMs, notUsed: notUsed)) else {
                Logger.warning("ad \(bidId.prefix(8)): \(event) beacon has an invalid URL")
                continue
            }
            send(url, event: event, part: part)
        }
        return fireID
    }

    /// Whether the ad has any entry named `event` for `part`.
    func has(_ event: String, part: String?) -> Bool {
        entries.contains { $0.event == event && $0.part == part }
    }

    private func send(_ url: URL, event: String, part: String?) {
        let label = part.map { "\(event) (\($0))" } ?? event
        BeaconClient.send(url, label: "ad \(adId.prefix(8)): \(label)", over: session)
    }

    /// Fires every `progress` entry the ad video has passed (`offset` at or below `playheadMs`) and not fired
    /// yet, each as its own occurrence. The page reports the checkpoint it saw; the SDK decides from the
    /// playhead, as VAST players do, so a checkpoint the page skipped (a stall, a seek) or rounded differently
    /// still fires.
    func fireProgress(upTo playheadMs: Int) {
        // Each checkpoint not fired yet, once, in order: entries sharing an offset fire as one occurrence with one
        // fire id. A checkpoint whose entries all fired is skipped without a fire id spent on it.
        for offset in progressOffsets {
            guard offset <= playheadMs else { break }
            guard progressByOffset[offset]?.contains(where: { !fired.contains($0) }) == true else { continue }
            fire("progress", offset: offset)
        }
    }

    /// `fireProgress` for a page event: nothing before `video.start`, which the protocol lets a mute, an unmute and a
    /// skip precede.
    private func catchUpProgress(upTo playheadMs: Int) {
        guard hasVideoStarted else { return }
        fireProgress(upTo: playheadMs)
    }

    /// The click-through with the beacon macros substituted, `[KONTEXT_FIREID]` with the click's own fire id:
    /// a redirect URL and the `click` beacon then arrive as one occurrence.
    func clickThrough(_ url: URL, fireID: String) -> URL {
        URL(string: substitute(url.absoluteString, errorCode: nil, fireID: fireID, viewDurationMs: nil, notUsed: nil)) ?? url
    }

    private func substitute(_ template: String, errorCode: Int?, fireID: String, viewDurationMs: Int?, notUsed: NotUsed?) -> String {
        TrackingMacros.substitute(template, contentPlayhead: { frozenContentPlayhead ?? contentPlayhead() }, adPlayheadMs: adPlayhead,
                                  errorCode: errorCode, fireID: fireID, viewDurationMs: viewDurationMs, notUsed: notUsed)
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
