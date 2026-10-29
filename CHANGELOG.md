# Changelog

## 0.2.0

In progress.

### Breaking
* `VideoAd.Click` no longer has `url`: `didClick` says where the viewer tapped (`area`), not what opened, as AdMob and AppLovin MAX do. The page's target was the advertiser's tracking link, often not what opened (a fallback, the App Store sheet), and the SDK opens it itself.

* `show(in:insets:)`: insets that keep an overlay or a pause card clear of your own controls, added to the view's safe area (`bottom: 80` puts a bottom strip 80 points above it). Kept through resizes and rotations, counted in `containerTooSmall`'s minimum; a full-screen pause ad ignores them. `show(in:)` is unchanged. Insets that leave no width or height throw `containerTooSmall` (or end a shown ad as `.interrupted` on a resize), however large.
* Error reports: when the server turns them on in `/config` (`reportErrors`), the SDK sends its faults (a failed request, a creative or frame page that broke, a presentation UIKit refused, an integration mistake) to `/v2/error`, as codes and ids, never personal data. New `VideoAds.lastRequestId`: quote it to Kontext when an ad or a no-fill looks wrong.
* `/config` is sent once, with no retry, like every other request; a retry policy comes later. After a failure the SDK is `.failed`, and the next `format()` tries `/config` again, as before.
* KontextKit 0.4.0. The volume in an ads request comes from KontextKit again, which since 0.4.0 reads it without touching the app's audio session. An app-install ad whose SKAdNetwork start Apple refused now still sends Apple the matching end.
* An overlay's `duration` and its on-screen time count while its window's scene is active, not the app: on iPad, a second window of the app taking the screen freezes them too.
* Ads never play in Picture in Picture or on an AirPlay screen, where nothing could measure them.
* A frame page whose connection drops after it started loading fails the ad at once (`didFail`), instead of waiting for the load timeout.
* Example app: leaving the player screen no longer restarts the content when `destroy()` ends an ad on screen.

## 0.1.0

Initial release: overlay, pause and linear ads for iOS, on the *Video Ads API & SDK v2* contract. Integration guide: https://docs.kontext.so/video/sdk/swift.
