# Changelog

## 0.2.0

In progress.

### Breaking
* `VideoAd.Click` no longer has `url`: `didClick` says where the viewer tapped (`area`), not what opened, as AdMob and AppLovin MAX do. The page's target was the advertiser's tracking link, often not what opened (a fallback, the App Store sheet), and the SDK opens it itself.

* Error reports: when the server turns them on in `/config` (`reportErrors`), the SDK sends its faults (a failed request, a creative or frame page that broke, a presentation UIKit refused, an integration mistake) to `/v2/error`, as codes and ids, never personal data. New `VideoAds.lastRequestId`: quote it to Kontext when an ad or a no-fill looks wrong.
* `/config` is sent once, with no retry, like every other request; a retry policy comes later. After a failure the SDK is `.failed`, and the next `format()` tries `/config` again, as before.
* KontextKit 0.4.0. The volume in an ads request comes from KontextKit again, which since 0.4.0 reads it without touching the app's audio session. An app-install ad whose SKAdNetwork start Apple refused now still sends Apple the matching end.

## 0.1.0

Initial release: overlay, pause and linear ads for iOS, on the *Video Ads API & SDK v2* contract. Integration guide: https://docs.kontext.so/video/sdk/swift.
