/// A placement is a piece of the publisher's inventory, created in the Kontext dashboard with a format
/// and an id the publisher chose (`episode-midroll`, `fullscreen-pause`). Demand, floors, frequency caps
/// and reporting are configured there; the SDK only sends the id. Every publisher starts with one per
/// format: `overlay`, `pause`, `interstitial`.
///
/// One object per placement, obtained once from `VideoAds` and kept, as MAX's `MAInterstitialAd` or
/// LevelPlay's `LPMInterstitialAd`. One unshown ad per placement at a time; `load` returns the ad, ready
/// to show, or throws a `VideoAdError` (no fill, busy placement, failed request, SDK not ready), or
/// `CancellationError`. `fetch` is the first half of `load`: the server's answer as a `VideoAd.Bid`,
/// nothing rendered, for an app that decides before rendering; `bid.load()` is the second half.

/// A strip across the player while the content plays. Shown in a window the server derived from the
/// content (timed mode) or at a moment the app picks (manual mode).
@MainActor
public final class OverlayPlacement {
    public let id: String
    private unowned let ads: VideoAds

    init(id: String, ads: VideoAds) {
        self.id = id
        self.ads = ads
    }

    /// Requests an overlay. `positions`: where the app can render it; the default is top and bottom.
    public func load(_ options: OverlayOptions = OverlayOptions()) async throws -> VideoAd {
        try await ads.load(FormatRequest(placementId: id, options: .overlay(options)))
    }

    /// Requests an overlay and returns the server's answer without rendering it; `bid.load()` renders.
    public func fetch(_ options: OverlayOptions = OverlayOptions()) async throws -> VideoAd.Bid {
        try await ads.fetch(FormatRequest(placementId: id, options: .overlay(options)))
    }
}

/// A card at the top or bottom, or the full player, while the content is paused.
@MainActor
public final class PausePlacement {
    public let id: String
    private unowned let ads: VideoAds

    init(id: String, ads: VideoAds) {
        self.id = id
        self.ads = ads
    }

    /// Requests a pause ad. `positions`: what the app can render; the default is top and bottom.
    public func load(_ options: PauseOptions = PauseOptions()) async throws -> VideoAd {
        try await ads.load(FormatRequest(placementId: id, options: .pause(options)))
    }

    /// Requests a pause ad and returns the server's answer without rendering it; `bid.load()` renders.
    public func fetch(_ options: PauseOptions = PauseOptions()) async throws -> VideoAd.Bid {
        try await ads.fetch(FormatRequest(placementId: id, options: .pause(options)))
    }
}

/// A full-screen video at a moment the app picks: before, during or after the content.
@MainActor
public final class InterstitialPlacement {
    public let id: String
    private unowned let ads: VideoAds

    init(id: String, ads: VideoAds) {
        self.id = id
        self.ads = ads
    }

    /// Requests an interstitial. `timing` says where the app will show it, `maxDuration` caps the
    /// video, `muted` starts it with the sound off, `rewarded` asks for a non-skippable video with a
    /// reward granted when it completes.
    public func load(_ options: InterstitialOptions = InterstitialOptions()) async throws -> VideoAd {
        try await ads.load(FormatRequest(placementId: id, options: .interstitial(options)))
    }

    /// Requests an interstitial and returns the server's answer without rendering it; `bid.load()` renders.
    public func fetch(_ options: InterstitialOptions = InterstitialOptions()) async throws -> VideoAd.Bid {
        try await ads.fetch(FormatRequest(placementId: id, options: .interstitial(options)))
    }
}
