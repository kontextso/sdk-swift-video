import Foundation

/// The macros of a tracking URL and how they are written: the IAB's (`[CACHEBUSTING]`, `[TIMESTAMP]`,
/// `[MEDIAPLAYHEAD]` and its deprecated twin `[CONTENTPLAYHEAD]`, `[ADPLAYHEAD]`, `[ERRORCODE]`) and our own,
/// prefixed `KONTEXT_` so they never collide with the IAB registry (`[REASON]` there is an integer for
/// verification pixels). A macro the SDK does not know stays in place. `Tracker` decides what fires and when;
/// this is only the text.
@MainActor
enum TrackingMacros {
    /// `template` with every macro the SDK knows filled in. `contentPlayhead` is read once, and only when the
    /// URL asks for it: its two names are one moment.
    static func substitute(_ template: String, contentPlayhead: () -> TimeInterval, adPlayheadMs: Int, errorCode: Int?,
                           fireId: String, viewDurationMs: Int?, notUsed: Tracker.NotUsed?) -> String {
        // A macro may arrive with its brackets encoded, one or both (a click-through parsed into a `URL`):
        // normalized first, so detection and substitution see the same string. The end re-encodes whatever
        // is left, so a bracket that was never a macro comes out as it went in.
        let normalized = decodingBrackets(template)
        let content = asksForContentPlayhead(normalized) ? encode(playhead(seconds: contentPlayhead())) : ""
        let substituted = normalized
            .replacingOccurrences(of: "[CACHEBUSTING]", with: String(format: "%08d", Int.random(in: 0..<100_000_000)))
            .replacingOccurrences(of: "[TIMESTAMP]", with: encode(timestamp.string(from: Date())))
            .replacingOccurrences(of: "[MEDIAPLAYHEAD]", with: content)
            .replacingOccurrences(of: "[CONTENTPLAYHEAD]", with: content)
            .replacingOccurrences(of: "[ADPLAYHEAD]", with: encode(playhead(seconds: TimeInterval(adPlayheadMs) / 1000)))
            .replacingOccurrences(of: "[ERRORCODE]", with: errorCode.map(String.init) ?? "")
            .replacingOccurrences(of: "[KONTEXT_FIREID]", with: fireId)
            .replacingOccurrences(of: "[KONTEXT_VIEWDURATION]", with: viewDurationMs.map(String.init) ?? "")
            .replacingOccurrences(of: "[KONTEXT_REASON]", with: notUsed?.reason ?? "")
            // A price that is not a price (NaN, infinite, negative) from the app's `reject` is left empty, not sent as `nan`.
            .replacingOccurrences(of: "[KONTEXT_WINNINGPRICE]", with: encode(notUsed?.winningPrice.flatMap { $0.isFinite && $0 >= 0 ? String($0) : nil } ?? ""))
            .replacingOccurrences(of: "[KONTEXT_WINNER]", with: encode(notUsed?.winner ?? ""))
        // A macro the SDK does not know stays, encoded: a bare `[` makes Foundation re-encode the whole
        // URL, and every `%3A` above would become `%253A`.
        return encodingBrackets(substituted)
    }

    /// Either name of the content playhead, its brackets encoded or not.
    static func asksForContentPlayhead(_ template: String) -> Bool {
        let normalized = decodingBrackets(template)
        return normalized.contains("[MEDIAPLAYHEAD]") || normalized.contains("[CONTENTPLAYHEAD]")
    }

    /// A macro's brackets as the tracker matches them: `%5B` and `%5D`, in either case, back to `[` and `]`.
    static func decodingBrackets(_ text: String) -> String {
        text.replacingOccurrences(of: "%5B", with: "[", options: .caseInsensitive)
            .replacingOccurrences(of: "%5D", with: "]", options: .caseInsensitive)
    }

    /// Brackets percent-encoded, as a URL carries them: `URL(string:)` refuses a bare one, or re-encodes the
    /// whole string around it. Not in the authority (`scheme://` up to the first `/`, `?` or `#`): there they
    /// delimit an IPv6 literal (`https://[2001:db8::1]:8080/p`), which encoded is no longer a host.
    static func encodingBrackets(_ text: String) -> String {
        let encode = { (part: Substring) in part.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D") }
        guard let separator = text.range(of: "://") else { return encode(text[...]) }
        let authorityEnd = text[separator.upperBound...].firstIndex { "/?#".contains($0) } ?? text.endIndex
        return encode(text[..<separator.upperBound]) + text[separator.upperBound..<authorityEnd] + encode(text[authorityEnd...])
    }

    /// Playheads beyond this (`TenYears`, the content playhead's cap too) are nonsense and clamped: a value near
    /// `Int.max` would trap the `Int` conversion below.
    static let maxPlayhead = TenYears.seconds

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

    /// `[TIMESTAMP]`: `YYYY-MM-DDTHH:MM:SS.mmm±HH:MM` in the device's zone.
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    /// A value inside one query parameter: only RFC 3986's unreserved characters stay, so `:` in a playhead,
    /// `+` in a price and `;`, `/` or `?` in a winner's name are no parser's delimiter.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: urlQueryValueAllowed) ?? value
    }

    /// RFC 3986 unreserved: letters, digits, `-._~`.
    private static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
