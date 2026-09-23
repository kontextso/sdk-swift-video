# Changelog

## Unreleased

* Every served ad carries its `ecpm` (USD per 1,000 impressions): `VideoAd.ecpm` on the placement's `pending` entries and on the ad handed to `overlay.onWindowOpen`, and `ecpm` next to `id` on each ad in the `.loaded` event. Apps that run their own auction can rank a Kontext ad before showing it.

* Initial SDK skeleton: `KontextVideo.createSession`, `VideoSession.attachPlayer` / `startVideo`, `VideoAds.showSwipeBanner`, format and event models, preload request sketch.
* Short-drama example app (home grid → fullscreen vertical episode player).
