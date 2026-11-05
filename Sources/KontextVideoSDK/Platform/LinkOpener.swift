import Foundation

/// Which links an ad may open, and opening them: the click-through of an `ad.click`, the target of an `ad.open`
/// (the AdChoices page), a navigation the page could not report.
///
/// Web, App Store and app deep links open, the host app's own included: which links an ad may carry is the ad
/// server's decision. Refused: the schemes that call, message or install something without a page in between,
/// and the ones that lead nowhere a viewer could go (`refusedSchemes`).
@MainActor
enum LinkOpener {
    /// Schemes a tap never opens, whatever the page says. The URL comes from whoever bought the ad, and
    /// `UIApplication.open` hands it to the app registered for it: these call, message or install something
    /// without a page in between (`tel:`, `sms:`, `facetime:`, an enterprise app install through
    /// `itms-services:`, a shortcut, the Settings app), or lead nowhere a viewer could go: `intent:` is an
    /// Android launch link with no meaning on iOS, and `javascript:`, `data:`, `file:`, `blob:` and `about:`
    /// would run or load in place.
    static let refusedSchemes: Set<String> = [
        "tel", "telprompt", "sms", "mms", "facetime", "facetime-audio", "itms-services", "shortcuts",
        "app-settings", "prefs", "app-prefs", "x-apple-reminderkit", "x-apple-health",
        "intent", "javascript", "data", "file", "blob", "about",
    ]

    /// A space or a control character makes a link unusable (iOS 17 would encode it and open something else).
    private static let unusableCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    /// A link that may open: one with a scheme that is not refused.
    static func isAllowed(_ target: URL) -> Bool {
        guard let scheme = target.scheme?.lowercased() else { return false }
        return !refusedSchemes.contains(scheme)
    }

    /// A link the page sent, if usable: no space or control character, and a host for a web link, as on Android.
    /// A click-through may carry a beacon macro (`[KONTEXT_FIREID]`): its brackets are percent-encoded first, or
    /// `URL(string:)` refuses the string (iOS 16) or re-encodes the whole of it (iOS 17); the tracker reads the
    /// encoded form.
    static func url(_ raw: String) -> URL? {
        guard !raw.unicodeScalars.contains(where: unusableCharacters.contains), let url = URL(string: TrackingMacros.encodingBrackets(raw)) else { return nil }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty ?? true { return nil }
        return url
    }

    /// Opens `url`, else `fallback` when the first cannot be opened (an app that is not installed) or may not
    /// be. `completion` says whether one of them opened.
    static func open(_ url: URL, fallback: URL?, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        openOne(url) { opened in
            guard !opened, let fallback else { return completion(opened) }
            openOne(fallback, completion: completion)
        }
    }

    private static func openOne(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        guard isAllowed(url) else {
            Logger.warning("the link \(url.absoluteString) is not allowed to open")
            return completion(false)
        }
        Environment.openURL(url, completion)
    }
}
