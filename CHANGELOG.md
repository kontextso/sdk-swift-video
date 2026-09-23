# Changelog

## Unreleased

### Breaking
`setVideo(id:…)` is now `createAds(videoId:…)`, and it no longer destroys the previous video's handle: handles are independent, so the next episode's ads can be created and loaded while the current one plays. Destroy each handle yourself with `await ads.destroy()` when the viewer is done with that video. `session.currentVideo` is gone.

The swipe format is gone; the interstitial replaces it. `VideoAdFormat.swipe` → `.interstitial` (`INSTREAM_VIDEO_INTERSTITIAL`), `ads.swipe` → `ads.interstitial`, and the SDK now presents the ad itself: `show(from: viewController, onDismissed:)` instead of `show(in: hostView, onSkippable:onFinished:)`. Pause your content before `show` and resume it in `onDismissed`; there is no gesture to unblock and no host view to provide.

* Interstitial ads: a full-screen video the SDK presents in its own controller at a moment the app chooses, with a Close chip that counts down the server's `skip_after_ms`, on the MAX / AdMob / LevelPlay interstitial model. After the video ends the last frame stays up until the viewer taps Close.
* Every served ad carries its `ecpm` (USD per 1,000 impressions): `VideoAd.ecpm` on the placement's `pending` entries and on the ad handed to `overlay.onWindowOpen`, and `ecpm` next to `id` on each ad in the `.loaded` event. Apps that run their own auction can rank a Kontext ad before showing it.

* Initial SDK skeleton: `KontextVideo.createSession`, `VideoSession.attachPlayer` / `startVideo`, `VideoAds.showSwipeBanner`, format and event models, preload request sketch.
* Short-drama example app (home grid → fullscreen vertical episode player).
