import Foundation

/// The Kontext Frame Protocol v2 as rules over plain values: which message the page may send in which state,
/// what it means, and what is dropped. No WebView, no timers, no clock of its own.
///
/// Why: the protocol's rules (the envelope, the sender, the order, the playhead's bounds, one URL per touch)
/// decide what an ad bills and opens. Kept apart from the WebView that carries them, each rule is a cell of a
/// table a test can read, and the Kotlin twin keeps the same names (`FrameProtocol`, `accept`, `Step`).
///
/// How: `FrameBridge` (the imperative shell) owns one `FrameProtocol`. For each message the page posts, it calls
/// `accept(_:from:now:)` and carries out the `Step` it returns; for the SDK's own moments it asks `show()`,
/// `end()`, `noteTouch(now:)`, `externalNavigation(to:now:)` and `navigationDecision(...)`.
///
/// ```
///   message           loading     loaded      shown                    ended
///   ad.loaded         loaded      ignore      ignore                   ignore
///   ad.click, ad.open ignore      ignore      deliver (touch, scheme)  ignore
///   ad.close          ignore      ignore      endThenDeliver           ignore
///   video.skip        ignore      ignore      endThenDeliver           ignore
///   video.start       ignore      ignore      deliver                  ignore
///   other video.*     ignore      ignore      deliver after start      ignore
///   video.<unknown>   ignore      ignore      ignore                   ignore
///   ad.error          endThenDeliver (code: the page's, else 400/500 before show, 405 after)   ignore
///   unknown type      drop        drop        drop                     ignore
/// ```
///
/// A message from another frame or origin is dropped; a malformed envelope, a video message before
/// `video.start` and a malformed progress offset are dropped as a protocol violation, reported once per ad.
@MainActor
struct FrameProtocol {
    enum State: Sendable {
        case loading
        case loaded
        case shown
        case ended
    }

    /// What the shell does with one message from the page.
    enum Step {
        /// Nothing: a message the state does not take, or one after the end.
        case ignore
        /// Dropped, with a line for the log (a warning when `warning`) and, the first time the page broke the
        /// contract, the violation to report.
        case drop(log: String, warning: Bool = false, violation: String? = nil)
        /// The page reported the creative ready: the state is loaded, the load timeout stops, the ad hears it.
        case loaded
        /// The event goes to the ad.
        case deliver(FrameEvent)
        /// The page ends (its close, its skip, its error): the shell ends the bridge, then delivers.
        case endThenDeliver(FrameEvent)
    }

    /// Where a message came from, as WebKit reports it.
    struct Sender: Equatable {
        let isMainFrame: Bool
        let scheme: String
        let host: String
        /// 0 for the scheme's default port.
        let port: Int
    }

    /// What a top-level navigation may do. While the page loads: its own origin (redirects included) and
    /// `about:blank`; anything else is a click the page could not report. Once it is ready the document
    /// stays: only a navigation within it (a fragment) goes through, and replacing it, even with a page of
    /// the same origin or a reload of itself, is refused, or the creative and its close control would vanish
    /// under an ad still shown. A navigation stays within the document, as browsers decide it, when the
    /// target carries a fragment and differs from the current URL in nothing else; a reload, a form submission
    /// or any request that is not a GET (`isSubmission`, whatever its fragment), or the current URL without a
    /// fragment, loads a new document. A subframe (the creative's own iframe) navigates freely.
    enum NavigationDecision: Equatable {
        case allow, cancel, external
    }

    /// A URL is opened only if the viewer touched the WebView this recently.
    static let touchWindow: TimeInterval = 1
    /// How far past the video's duration a page playhead may go: the page's rounding, not more.
    static let playheadGraceMs = 1000
    /// The largest message string parsed, in UTF-8 bytes (1 MB); every message of the protocol is far smaller.
    static let maxMessageBytes = 1024 * 1024
    /// Schemes a tap never opens, whatever the page says. The URL comes from whoever bought the ad, and
    /// `UIApplication.open` hands it to the app registered for it: these call, message or install something
    /// without a page in between (`tel:`, `sms:`, `facetime:`, an enterprise app install through
    /// `itms-services:`, a shortcut, the Settings app), or lead nowhere a viewer could go: `intent:` is an
    /// Android launch link with no meaning on iOS, and `javascript:`, `data:`, `file:`, `blob:` and `about:`
    /// would run or load in place. Web, App Store and app deep links open, the host app's own included: which
    /// links an ad may carry is the ad server's decision.
    static let refusedSchemes: Set<String> = [
        "tel", "telprompt", "sms", "mms", "facetime", "facetime-audio", "itms-services", "shortcuts",
        "app-settings", "prefs", "app-prefs", "x-apple-reminderkit", "x-apple-health",
        "intent", "javascript", "data", "file", "blob", "about",
    ]

    let adId: String
    /// The page the bridge loaded: its origin is the only one whose messages count.
    let pageURL: URL
    /// The VAST error code when the page itself does not answer: 400 for a video, 500 otherwise.
    let loadErrorCode: Int
    /// The highest playhead a page may report, in milliseconds: the video's duration and the grace, or a day.
    let playheadLimitMs: Int
    private(set) var state: State = .loading
    /// `video.start` arrived: the video's progress, quartiles, pause, resume and complete count only after it.
    private var isVideoStarted = false
    /// A page that broke the message contract is reported once: a loop of bad messages is one fault.
    private var hasReportedViolation = false
    private var lastTouchAt: TimeInterval = -.infinity

    /// `videoDuration`: the video's length when the server gives one (a linear ad); without it the playhead is
    /// capped at a day.
    init(adId: String, pageURL: URL, isVideo: Bool, videoDuration: TimeInterval?) {
        self.adId = adId
        self.pageURL = pageURL
        loadErrorCode = isVideo ? 400 : 500
        playheadLimitMs = videoDuration.map { min(Int(($0 * 1000).rounded()) + Self.playheadGraceMs, 86_400_000) } ?? 86_400_000
    }

    /// The code of a failure the bridge decides itself (the page replaced, the web process gone): 405 while
    /// shown, the load error code before.
    var failureCode: Int { state == .shown ? 405 : loadErrorCode }

    // MARK: Page → SDK

    /// Checks the sender, the envelope and the order of one message; `now` is the clock a click's touch is
    /// measured on.
    mutating func accept(_ rawBody: Any, from sender: Sender, now: TimeInterval) -> Step {
        guard state != .ended else { return .ignore }
        guard sender.isMainFrame, isFrameOrigin(sender) else { return .drop(log: "message from another frame dropped") }
        guard let body = Self.messageObject(rawBody), body["adId"] as? String == adId, let type = body["type"] as? String else {
            return .drop(log: "malformed message dropped", violation: violation("envelope"))
        }
        // Milliseconds into the ad video, a fraction rounded (a page reads `currentTime * 1000`), clamped to the
        // video's duration (a day without one): a playhead past the end would fire every checkpoint at once.
        let rawPlayhead = (body["playhead"] as? NSNumber)?.doubleValue ?? 0
        let playhead = rawPlayhead.isFinite ? Int(min(max(0, rawPlayhead), Double(playheadLimitMs)).rounded()) : 0

        switch type {
        case "ad.loaded":
            guard state == .loading else { return .ignore }
            state = .loaded
            return .loaded
        case "ad.click", "ad.open":
            return acceptOpening(type, body, now: now)
        case "ad.close":
            guard state == .shown else { return .ignore }
            return .endThenDeliver(.close(reason: (body["reason"] as? String).flatMap(FrameEvent.CloseReason.init(rawValue:)) ?? .close))
        case "video.skip":
            guard state == .shown else { return .ignore }
            return .endThenDeliver(.skip(playhead: playhead))
        case let type where type.hasPrefix("video."):
            return acceptVideo(type, body, playhead: playhead)
        case "ad.error":
            // A VAST error code has three digits; any other code from the page goes as 900, undefined error.
            let given = (body["code"] as? NSNumber)?.doubleValue
            let code = given.map { (100...999).contains($0) ? Int($0) : 900 } ?? (state == .shown ? 405 : loadErrorCode)
            return .endThenDeliver(.error(code: code))
        default:
            return .drop(log: "unknown message \(type) dropped")
        }
    }

    /// `ad.click` or `ad.open`: on screen only, to a usable URL of an allowed scheme, after a touch.
    private mutating func acceptOpening(_ type: String, _ body: [String: Any], now: TimeInterval) -> Step {
        guard state == .shown else { return .ignore }
        // A click whose `url` is missing or unusable but whose `fallbackUrl` is good opens the fallback.
        let given = (body["url"] as? String).flatMap(Self.url)
        let fallback = type == "ad.click" ? (body["fallbackUrl"] as? String).flatMap(Self.url) : nil
        guard let url = given ?? fallback else { return .ignore }
        guard let target = Self.target(url, fallback: given == nil ? nil : fallback) else {
            return .drop(log: "\(type) to \(url.absoluteString) dropped, scheme refused", warning: true)
        }
        guard consumeTouch(now: now) else {
            return .drop(log: "\(type) to \(url.absoluteString) dropped, no touch before it", warning: true)
        }
        if type == "ad.click" {
            return .deliver(.click(url: target.url, fallbackUrl: target.fallback, area: VideoAd.Click.Area(body["area"] as? String)))
        }
        return .deliver(.open(url: url, purpose: body["purpose"] as? String ?? "unknown"))
    }

    /// A `video.*` message: on screen only; everything but the start, mute and unmute after `video.start`.
    private mutating func acceptVideo(_ type: String, _ body: [String: Any], playhead: Int) -> Step {
        guard state == .shown else { return .ignore }
        switch type {
        case "video.complete":
            if let dropped = droppedBeforeStart(type) { return dropped }
            return .deliver(.complete(playhead: playhead))
        case "video.progress":
            if let dropped = droppedBeforeStart(type) { return dropped }
            // A checkpoint in milliseconds within a day, a fraction rounded to the nearest; anything else would
            // fire every checkpoint early.
            guard let raw = (body["offset"] as? NSNumber)?.doubleValue, raw.isFinite, (0...86_400_000).contains(raw) else {
                return .drop(log: "video.progress with a malformed offset dropped", violation: violation("progress.offset"))
            }
            return .deliver(.progress(offset: min(Int(raw.rounded()), playheadLimitMs), playhead: playhead))
        default:
            guard let event = FrameEvent.VideoEvent(rawValue: String(type.dropFirst("video.".count))) else { return .ignore }
            // `video.start` opens the video; mute and unmute are the viewer's and may come while it still loads;
            // the rest need the start before them.
            switch event {
            case .start: isVideoStarted = true
            case .mute, .unmute: break
            default: if let dropped = droppedBeforeStart(type) { return dropped }
            }
            return .deliver(.video(event, playhead: playhead))
        }
    }

    /// The message as an object: a JSON string that parses to one (at most `maxMessageBytes`), or an object
    /// as WebKit converted it. `nil` for anything else.
    static func messageObject(_ rawBody: Any) -> [String: Any]? {
        if let object = rawBody as? [String: Any] { return object }
        guard let text = rawBody as? String, text.utf8.count <= maxMessageBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// `nil` when `video.start` came before this video message; otherwise the drop: progress, quartiles or a
    /// complete for a video that never started would be billed with no impression.
    private mutating func droppedBeforeStart(_ type: String) -> Step? {
        guard !isVideoStarted else { return nil }
        return .drop(log: "\(type) before video.start dropped", violation: violation("video.beforeStart"))
    }

    /// The page broke the message contract: a fault of the frame page, reported once per ad, so `detail` the
    /// first time and `nil` after. Only a message from the ad's own page, before the end, can be one. A message
    /// from another frame, one after the end, or one of an unknown type is not: creatives post messages of
    /// their own, late messages are expected, and a newer page may send types this SDK does not know yet.
    private mutating func violation(_ detail: String) -> String? {
        guard !hasReportedViolation else { return nil }
        hasReportedViolation = true
        return detail
    }

    // MARK: The SDK's moments

    /// The page goes on screen; `false` (and nothing changes) unless it is loaded.
    mutating func show() -> Bool {
        guard state == .loaded else { return false }
        state = .shown
        return true
    }

    /// Terminal; `false` when it already ended.
    mutating func end() -> Bool {
        guard state != .ended else { return false }
        state = .ended
        return true
    }

    // MARK: Touches and URLs

    /// The viewer touched the WebView; a URL may be opened for `touchWindow` seconds.
    mutating func noteTouch(now: TimeInterval) {
        lastTouchAt = now
    }

    /// One tap opens one URL: the touch is spent by the first click, open or navigation it authorized, so a
    /// page that reports a tap and also navigates on it does not open twice.
    private mutating func consumeTouch(now: TimeInterval) -> Bool {
        guard now - lastTouchAt <= Self.touchWindow else { return false }
        lastTouchAt = -.infinity
        return true
    }

    /// A navigation out of our origin is a click the page could not report: honoured only after a touch;
    /// without one it is a forced redirect and goes nowhere (`nil`).
    mutating func externalNavigation(to target: URL, now: TimeInterval) -> FrameEvent? {
        guard state == .shown, Self.isAllowed(target), consumeTouch(now: now) else { return nil }
        return .click(url: target, fallbackUrl: nil, area: .creative)
    }

    /// A URL the page may have opened: anything but the refused schemes.
    static func isAllowed(_ target: URL) -> Bool {
        guard let scheme = target.scheme?.lowercased() else { return false }
        return !refusedSchemes.contains(scheme)
    }

    /// What a click or open goes to under `isAllowed`, `nil` when nothing may open. The fallback is held to the
    /// same policy: a refused one is dropped and the URL stays; a refused URL with an allowed fallback opens
    /// the fallback instead.
    static func target(_ url: URL, fallback: URL?) -> (url: URL, fallback: URL?)? {
        let fallback = fallback.flatMap { isAllowed($0) ? $0 : nil }
        if isAllowed(url) { return (url, fallback) }
        return fallback.map { ($0, nil) }
    }

    /// A URL the page sent. A click-through may carry a beacon macro (`[KONTEXT_FIREID]`): its brackets are
    /// percent-encoded first, or `URL(string:)` refuses the string (iOS 16) or re-encodes the whole of it
    /// (iOS 17); the tracker reads the encoded form.
    static func url(_ raw: String) -> URL? {
        // As on Android: a space or a control character makes a URL unusable (iOS 17 would encode it and open
        // something else), and so does a web link without a host.
        let unusable = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !raw.unicodeScalars.contains(where: unusable.contains), let url = URL(string: Tracker.encodingBrackets(raw)) else { return nil }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty ?? true { return nil }
        return url
    }

    // MARK: Origins and navigation

    /// The page's origin and nothing else. WebKit reports port 0 for a scheme's default port, so an
    /// explicit 443 in the URL and the origin's 0 are the same origin.
    func isFrameOrigin(_ sender: Sender) -> Bool {
        isPageOrigin(scheme: sender.scheme, host: sender.host, port: sender.port == 0 ? Self.defaultPort(for: sender.scheme) : sender.port)
    }

    /// Whether `target` is in the page's origin, with the default port and an explicit one the same.
    func isSameOrigin(_ target: URL) -> Bool {
        isPageOrigin(scheme: target.scheme, host: target.host, port: Self.effectivePort(of: target))
    }

    /// Scheme and host compare without case, as browsers canonicalize them; Foundation keeps the case as
    /// written. `port` is the effective one, the scheme's default when none was given.
    private func isPageOrigin(scheme: String?, host: String?, port: Int) -> Bool {
        scheme?.lowercased() == pageURL.scheme?.lowercased() && host?.lowercased() == pageURL.host?.lowercased()
            && port == Self.effectivePort(of: pageURL)
    }

    private static func effectivePort(of url: URL) -> Int {
        url.port ?? defaultPort(for: url.scheme)
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return 0
        }
    }

    /// See `NavigationDecision`.
    func navigationDecision(to target: URL, isMainFrame: Bool, isReload: Bool = false, isSubmission: Bool = false,
                            current: URL?) -> NavigationDecision {
        guard isMainFrame else { return .allow }
        let ours = isSameOrigin(target) || target.absoluteString == "about:blank"
        if state == .loading { return ours ? .allow : .external }
        if let current, !isReload, !isSubmission, target.fragment != nil, Self.withoutFragment(target) == Self.withoutFragment(current) { return .allow }
        return ours ? .cancel : .external
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}
