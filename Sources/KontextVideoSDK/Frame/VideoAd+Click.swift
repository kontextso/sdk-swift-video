import Foundation

/// Where a click goes: the App Store sheet of an app-install ad, or the URL.
extension VideoAd {
    /// The page's `ad.click`: the `click` beacon, the click-through with the same fire id, then `didClick`.
    func click(_ url: URL, fallback fallbackUrl: URL?, area: Click.Area) {
        Logger.info("ad \(id.prefix(8)): click (\(area)) \(url.absoluteString)")
        // The end card selects its own `click` entries; anything else, and an end-card click on an ad without
        // them (an overlay or pause ad), is the creative's: every accepted click is counted.
        // One occurrence: the beacon and the click-through carry the same fire id (Tracking Events page).
        let fireId = tracker.fire("click", part: area == .endCard && tracker.has("click", part: "endCard") ? "endCard" : nil)
        openClick(tracker.clickThrough(url, fireId: fireId), fallback: fallbackUrl.map { tracker.clickThrough($0, fireId: fireId) })
        // The delegate hears nothing after `didEnd`. Opening the click-through does not end the ad today; the check
        // keeps that rule if it ever does.
        guard !hasEnded else { return }
        delegate?.videoAd(self, didClick: Click(area: area))
    }

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
