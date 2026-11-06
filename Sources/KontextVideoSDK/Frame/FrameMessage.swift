import Foundation

/// One message of the ad's page, read: its envelope checked and its fields taken out, with no rule of the
/// protocol applied. What a message means in the page's state is `FrameProtocol`'s.
///
/// Why apart: reading the message (the limit, the JSON, the envelope, the field types, the playhead's bounds) is
/// a different job from the protocol's rules, and each is tested as its own table (`FrameMessageTests`).
///
/// ```
///   raw ── a string over maxMessageBytes ─┐
///       ── not JSON, not an object ───────┼─► nil: a broken envelope
///       ── another ad's id, no type ──────┘
///       ── otherwise ─────────────────────► FrameMessage(type, playheadMs, offset, url, …)
/// ```
struct FrameMessage: Equatable {
    /// `ad.loaded`, `ad.click`, `video.start`, …; never checked against the protocol's types here.
    let type: String
    /// Milliseconds into the ad video, a fraction rounded to the nearest (a page reads `currentTime * 1000`),
    /// clamped to the limit given to `parse`; 0 when absent, not a number (a boolean is not one) or not finite.
    let playheadMs: Int
    /// `video.progress`'s checkpoint as sent, a JSON number (a string or a boolean is not one); `nil` otherwise.
    let offset: Double?
    /// A click's or an open's link, as sent.
    let url: String?
    /// A click's second link, when its first may not open.
    let fallbackUrl: String?
    /// `ad.error`'s code as sent, a JSON number (a boolean is not one).
    let code: Double?
    /// Where a click landed (`creative`, `endCard`, a label of the page's own).
    let area: String?
    /// Why the page asks to open a link (`ad.open`).
    let purpose: String?
    /// Why the page closed itself (`ad.close`).
    let reason: String?

    /// The largest message string parsed, in UTF-8 bytes (1 MB); every message of the protocol is far smaller.
    static let maxMessageBytes = 1024 * 1024

    /// Reads `rawBody` (a JSON string, or an object as WebKit converted it) as a message of the page of ad `adId`,
    /// its playhead clamped to `playheadLimitMs`. `nil` for a broken envelope: a string over `maxMessageBytes`
    /// (never parsed), not a JSON object, another ad's id, or no type.
    static func parse(_ rawBody: Any, adId: String, playheadLimitMs: Int) -> FrameMessage? {
        guard let body = object(rawBody), body["adId"] as? String == adId, let type = body["type"] as? String else { return nil }
        // Clamped: a playhead past the end would fire every checkpoint at once.
        let rawPlayhead = number(body["playhead"]) ?? 0
        let playhead = rawPlayhead.isFinite ? Int(min(max(0, rawPlayhead), Double(playheadLimitMs)).rounded()) : 0
        return FrameMessage(
            type: type,
            playheadMs: playhead,
            offset: number(body["offset"]),
            url: body["url"] as? String,
            fallbackUrl: body["fallbackUrl"] as? String,
            code: number(body["code"]),
            area: body["area"] as? String,
            purpose: body["purpose"] as? String,
            reason: body["reason"] as? String
        )
    }

    /// A JSON number, or `nil`. `JSONSerialization` gives `true` and `false` as `NSNumber`s too; they are not
    /// numbers (`{"code":true}` must not go out as error 1), as the Kotlin SDK reads them.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// The message as an object: a JSON string that parses to one (at most `maxMessageBytes`), or an object
    /// as WebKit converted it. `nil` for anything else.
    private static func object(_ rawBody: Any) -> [String: Any]? {
        if let object = rawBody as? [String: Any] { return object }
        guard let text = rawBody as? String, text.utf8.count <= maxMessageBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
