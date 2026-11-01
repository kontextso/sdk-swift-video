import Foundation

/// Where a click goes: the App Store sheet of an app-install ad, or the URL.
extension VideoAd {
    /// A click: an app-install ad whose network signed the click opens the App Store product sheet inside
    /// the app, with the attribution; every other ad, and a sheet that could not be presented, opens the URL.
    func openClick(_ url: URL, fallback: URL?) {
        guard let skAdNetwork, skAdNetwork.skan.hasFidelity1 else { return Self.open(url, fallback: fallback) }
        // The viewer's tap is honored even if the ad ends while the sheet loads: the URL opens when it fails.
        Task {
            if await skAdNetwork.presentStore() { return }
            Self.open(url, fallback: fallback)
        }
    }

    /// Opens a URL the page asked for: the app store, a deep link, a web page. The fallback is tried when
    /// the first cannot be opened (an app that is not installed).
    static func open(_ url: URL, fallback: URL?) {
        Environment.openURL(url) { opened in
            if !opened, let fallback {
                Environment.openURL(fallback) { _ in }
            }
        }
    }
}
