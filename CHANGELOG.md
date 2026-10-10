# Changelog

## Unreleased

First release of the Kontext Video SDK for iOS: manual-mode v1 of the *Video Ads API & SDK v2* contract.

* `KontextVideo.shared.initialize(with:)` (fire-and-forget, `async`, or with a completion), `user`, `regulatory` and `variantId` set later from anywhere.
* `KontextVideoPlayer` protocol (the content's view and playhead) with `KontextVideo.AVPlayerAdapter` for `AVPlayer` and `AVPlayerViewController`.
* `VideoAds(content:player:)` per video, `start()` when the content plays; one started `VideoAds` per player.
* Placements by dashboard id: `overlayPlacement`, `pausePlacement`, `interstitialPlacement`; `try await placement.load(options)` returns a `VideoAd` that is ready to present, or throws `VideoAdError` (`noFill`, `placementBusy`, `invalidPlacement`, `creativeFailed`, ...).
* `VideoAd.show()` for overlay and pause ads inside the player's view, `show(from:)` for full-screen interstitials, `dismiss()` for the non-linear formats; `VideoAdDelegate` with exactly one `didEnd(reason:)` per successful show.
* Tracking: every VAST entry fired once by the SDK with the macros substituted; viewability (`viewable` / `notViewable` / `viewUndetermined`); the Kontext Frame Protocol v2 with the page.
* App Tracking Transparency on request, IDFA only when authorized, consent read from the CMP's IAB keys; `/init` kill switch and retry; `/debug` reporting when the server asks.
* Privacy manifest (`PrivacyInfo.xcprivacy`).
