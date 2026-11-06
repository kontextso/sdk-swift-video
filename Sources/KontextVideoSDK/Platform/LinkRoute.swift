import Foundation

/// Where a link an ad may open goes: into the app it names, into the App Store, or onto the web.
///
/// Why: a web link opens in the in-app browser, so the viewer stays in the app and the ad is only covered; a link
/// meant for an app must still reach that app. The scheme and the host decide, before anything opens:
///
/// ```
/// link                                              route    opened by LinkOpener
/// brandapp://offer, hostapp://premium               .app     the app it names (UIApplication.open)
/// itms-apps://…, https://apps.apple.com/…,          .store   the App Store app (UIApplication.open)
///   https://itunes.apple.com/…
/// https://brand.test/offer, http://brand.test       .web     the app that claims it (a universal link), else
///                                                            the in-app browser, else Safari
/// ```
///
/// Pure: `LinkOpener` asks it for a link `isAllowed` let through; the refused schemes are not its concern.
enum LinkRoute: Equatable {
    /// A custom scheme: the app registered for it opens it.
    case app
    /// The App Store, by its own scheme or a store web link: opened in the App Store app.
    case store
    /// Any other `http` or `https` link.
    case web

    /// The hosts of store web links, a subdomain included (`geo.itunes.apple.com`).
    static let storeHosts = ["apps.apple.com", "itunes.apple.com"]
    /// The App Store's own schemes.
    static let storeSchemes: Set<String> = ["itms-apps", "itms-appss"]

    init(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if Self.storeSchemes.contains(scheme) {
            self = .store
        } else if scheme == "http" || scheme == "https" {
            let host = url.host?.lowercased() ?? ""
            self = Self.storeHosts.contains { host == $0 || host.hasSuffix(".\($0)") } ? .store : .web
        } else {
            self = .app
        }
    }
}
