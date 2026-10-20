/// A placement is a piece of the publisher's inventory, created in the Kontext dashboard with a format
/// and an id the publisher chose (`episode-midroll`, `fullscreen-pause`). Demand, floors, frequency caps
/// and reporting are configured there; the SDK only sends the id. Every publisher starts with one per
/// format: `overlay`, `pause`, `linear`.
///
/// One object per placement, obtained once from `VideoAds` and kept, as MAX's `MAInterstitialAd` or
/// LevelPlay's `LPMInterstitialAd`. `OverlayPlacement`, `PausePlacement` and `LinearPlacement` are this
/// class with the format's options. One unshown ad per placement at a time; `load` returns the ad, ready
/// to show, or throws a `VideoAdError` (no fill, busy placement, failed request, SDK not ready), or
/// `CancellationError`. `fetch` is the first half of `load`: the server's answer as a `VideoAd.Bid`,
/// nothing rendered, for an app that decides before rendering; `bid.load()` is the second half.
@MainActor
public final class Placement<Options: PlacementOptions> {
    public let id: String
    private unowned let ads: VideoAds

    init(id: String, ads: VideoAds) {
        self.id = id
        self.ads = ads
    }

    /// Requests an ad and renders it: ready to show, or throws. See the options type for what can be asked.
    public func load(_ options: Options = .default) async throws -> VideoAd {
        try await ads.load(FormatRequest(placementId: id, options: options.formatOptions))
    }

    /// Requests an ad and returns the server's answer without rendering it; `bid.load()` renders.
    public func fetch(_ options: Options = .default) async throws -> VideoAd.Bid {
        try await ads.fetch(FormatRequest(placementId: id, options: options.formatOptions))
    }
}

/// A strip across the player while the content plays, shown at a moment the app picks.
public typealias OverlayPlacement = Placement<OverlayOptions>
/// A card at the top or bottom, or the full player, while the content is paused.
public typealias PausePlacement = Placement<PauseOptions>
/// A full-screen video at a moment the app picks: before, during or after the content.
public typealias LinearPlacement = Placement<LinearOptions>

/// The options of one format, as a placement's `load` and `fetch` take them.
public protocol PlacementOptions: Sendable {
    /// Every option left to its default.
    static var `default`: Self { get }
    /// The `options` object of the request, tagged with the format.
    var formatOptions: FormatOptions { get }
}
