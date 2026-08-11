import Foundation

/// Loads the bundled mock VMAP response — one overlay (at 1s), one pause ad,
/// one swipe banner, each with an inline creative — so rendering can be
/// developed and demoed without the ad server.
/// Enabled via `VideoSessionOptions(adsSource: .mock)`.
enum MockAdsLoader {
    static func load() throws -> [InstreamAd] {
        let url = Bundle.module.url(forResource: "MockAdsResponse", withExtension: "xml")!
        return VMAPParser.parse(try Data(contentsOf: url))
    }
}
