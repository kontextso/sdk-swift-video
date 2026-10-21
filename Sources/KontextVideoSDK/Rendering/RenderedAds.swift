import Foundation

/// The rendered, unshown ads of the whole app, for the render budget (`VideoAds.renderBudget`): an ad
/// joins when its page starts loading and leaves when shown, invalidated or deallocated. Weak, so a
/// dropped ad leaves by itself.
@MainActor
enum RenderedAds {
    private struct Entry { weak var value: VideoAd? }
    private static var ads: [Entry] = []

    static var count: Int {
        ads.removeAll { $0.value == nil }
        return ads.count
    }

    static func add(_ ad: VideoAd) {
        ads.append(Entry(value: ad))
    }

    static func remove(_ ad: VideoAd) {
        ads.removeAll { $0.value == nil || $0.value === ad }
    }

    static func reset() {
        ads = []
    }
}
