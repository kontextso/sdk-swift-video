# Changelog

## Unreleased

First release of the Kontext Video SDK for iOS, v1 of the *Video Ads API & SDK v2* contract.

* `KontextVideo.shared.initialize(with:)` (fire-and-forget, `async`, or with a completion), `user` (id, email or its hash, keywords; no demographics, OpenRTB 2.6 deprecated `yob` and `gender`), `regulatory` and `variantId` set later from anywhere.
* `VideoAds(content:playerSize:)` per video, full screen by default; the SDK reads the content playhead through `trackPlayhead(of: AVPlayer)` or `playheadProvider` when it needs one. No player protocol, nothing to start.
* Placements by dashboard id: `overlayPlacement`, `pausePlacement`, `linearPlacement`; `try await placement.load(options)` returns a `VideoAd` that is ready to present, or throws `VideoAdError` (`noFill`, `placementBusy`, `invalidPlacement`, `creativeFailed`, ...). One unshown ad per placement at a time; the next one may load while the current one is on screen. A failed `/init` is retried by every load. `placement.fetch(options)` is the first half of `load`: the server's answer as a `VideoAd.Bid` (`price`, `expirationDate`, `size`, ...) with nothing rendered, for apps that decide before rendering; `bid.load()` is the second half.
* `VideoAd.show(in:)` for overlay and pause ads inside the view the content plays in, `show()` / `show(from:)` for full-screen linear ads (the presenter found on the key window, or named; `.presenterUnavailable` when none can present), `dismiss()` for the non-linear formats; an overlay is removed by the SDK when its `duration` elapses (`didEnd(.completed)`), `OverlayOptions.maxDuration` caps it at request time; `VideoAdDelegate` with exactly one `didEnd(reason:)` per successful show and no "did show" callback (`show` returning is the signal); a linear ad closed before `complete` ends `.skipped`, `.closed` is for overlay and pause ads.
* Timed mode: `videoAdDidReachWindow` on the ad's delegate when its window opens, `VideoAdsTimingDelegate` (`ads.timingDelegate`) when a load is due (`nextRequestAt` reached, a seek, a discarded ad); the SDK samples the playhead every 250 ms only while it has something to watch, treats a jump over 2 s as a seek, discards pending windowed ads on a seek (`.seeked`) and ads whose window closed unshown (`.windowPassed`); a window that opens before `ad.delegate` is set is delivered the moment it is.
* Tracking: every VAST entry fired once by the SDK with the macros substituted; viewability (`viewable` / `notViewable` / `viewUndetermined`); the Kontext Frame Protocol v2 with the page.
* App Tracking Transparency on request, IDFA only when authorized, consent read from the CMP's IAB keys; `/init` kill switch and retry; `/debug` reporting when the server asks.
* Privacy manifest (`PrivacyInfo.xcprivacy`).
* Tests: 230+ Swift Testing cases, 93 % line coverage, including whole flows through a real `WKWebView`; CI on every push.
