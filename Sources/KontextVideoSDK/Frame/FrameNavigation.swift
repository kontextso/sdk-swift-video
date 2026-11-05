import Foundation

/// What a top-level navigation of the ad's page may do, and when a navigation out is a click.
///
/// The decision. While the page loads: its own origin (redirects included) and
/// `about:blank`; anything else is a click the page could not report. Once it is ready the document
/// stays: only a navigation within it (a fragment) goes through, and replacing it, even with a page of
/// the same origin or a reload of itself, is refused, or the creative and its close control would vanish
/// under an ad still shown. A navigation stays within the document, as browsers decide it, when the
/// target carries a fragment and differs from the current URL in nothing else; a reload, a form submission
/// or any request that is not a GET (`isSubmission`, whatever its fragment), or the current URL without a
/// fragment, loads a new document. A subframe (the creative's own iframe) navigates freely.
///
/// ```
///   target                          loading     loaded or shown
///   the page's origin, about:blank  allow       cancel (it would replace the creative)
///   the same URL with a fragment    allow       allow (within the document)
///   anywhere else                   external    external (a click, after a touch)
///   a subframe, anything            allow       allow
/// ```
///
/// A navigation out (`external`) is a click the page could not report: `click(to:...)` honours it only while
/// the page is shown, to an allowed link, after a touch (`TouchGate`). `FrameProtocol` holds one and reads it in
/// the frame's phase; the bridge's navigation delegate acts on the decision.
struct FrameNavigation {
    enum Decision: Equatable {
        case allow, cancel, external
    }

    /// The page the bridge loaded: its origin is the only one that counts as the page's.
    let pageURL: URL

    /// The decision for a navigation to `target` in `phase`; see the type's doc.
    func decision(to target: URL, isMainFrame: Bool, isReload: Bool = false, isSubmission: Bool = false,
                  current: URL?, phase: FramePhase) -> Decision {
        guard isMainFrame else { return .allow }
        let ours = isSameOrigin(target) || target.absoluteString == "about:blank"
        if phase == .loading { return ours ? .allow : .external }
        if let current, !isReload, !isSubmission, target.fragment != nil, Self.withoutFragment(target) == Self.withoutFragment(current) { return .allow }
        return ours ? .cancel : .external
    }

    /// A navigation out of our origin as the click the page could not report: only while it is shown, to a link
    /// `LinkOpener` allows, after a touch, which it spends; without one it is a forced redirect and goes nowhere
    /// (`nil`).
    @MainActor
    static func click(to target: URL, phase: FramePhase, touch: inout TouchGate, now: TimeInterval) -> FrameEvent? {
        guard phase == .shown, LinkOpener.isAllowed(target), touch.consume(now: now) else { return nil }
        return .click(url: target, fallbackUrl: nil, area: .creative)
    }

    /// Whether `target` is in the page's origin, with the default port and an explicit one the same.
    func isSameOrigin(_ target: URL) -> Bool {
        isPageOrigin(scheme: target.scheme, host: target.host, port: Self.effectivePort(of: target))
    }

    /// Scheme and host compare without case, as browsers canonicalize them; Foundation keeps the case as
    /// written. `port` is the effective one, the scheme's default when none was given.
    func isPageOrigin(scheme: String?, host: String?, port: Int) -> Bool {
        scheme?.lowercased() == pageURL.scheme?.lowercased() && host?.lowercased() == pageURL.host?.lowercased()
            && port == Self.effectivePort(of: pageURL)
    }

    /// The port a scheme uses when a URL gives none: 443 for https, 80 for http.
    static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return 0
        }
    }

    private static func effectivePort(of url: URL) -> Int {
        url.port ?? defaultPort(for: url.scheme)
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}
