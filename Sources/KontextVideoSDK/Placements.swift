/// A strip across the player while the content plays. Shown in a window the server derived from the
/// content (timed mode) or at a moment the app picks (manual mode).
@MainActor
public final class OverlayAd {
    private unowned let ads: VideoAds

    init(ads: VideoAds) {
        self.ads = ads
    }

    /// Requests an overlay. `positions`: where the app can render it; the default is top and bottom.
    public func load(_ options: OverlayOptions = OverlayOptions()) {
        ads.load(.overlay(options))
    }
}

/// A card at the top or bottom, or the full player, while the content is paused.
@MainActor
public final class PauseAd {
    private unowned let ads: VideoAds

    init(ads: VideoAds) {
        self.ads = ads
    }

    /// Requests a pause ad. `positions`: what the app can render; the default is top and bottom.
    public func load(_ options: PauseOptions = PauseOptions()) {
        ads.load(.pause(options))
    }
}

/// A full-screen video at a moment the app picks: before, during or after the content.
@MainActor
public final class InterstitialAd {
    private unowned let ads: VideoAds

    init(ads: VideoAds) {
        self.ads = ads
    }

    /// Requests an interstitial. `timing` says where the app will show it, `maxDuration` caps the
    /// video, `muted` starts it with the sound off, `rewarded` asks for a non-skippable video with a
    /// reward granted when it completes.
    public func load(_ options: InterstitialOptions = InterstitialOptions()) {
        ads.load(.interstitial(options))
    }
}
