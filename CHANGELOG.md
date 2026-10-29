# Changelog

## 0.2.0

In progress.

* Error reports: when the server turns them on in `/config` (`reportErrors`), the SDK sends its faults (a failed request, a creative or frame page that broke, a presentation UIKit refused, an integration mistake) to `/v2/error`, as codes and ids, never personal data. New `VideoAds.lastRequestId`: quote it to Kontext when an ad or a no-fill looks wrong.
* KontextKit 0.4.0. The volume in an ads request comes from KontextKit again, which since 0.4.0 reads it without touching the app's audio session. An app-install ad whose SKAdNetwork start Apple refused now still sends Apple the matching end.

## 0.1.0

Initial release: overlay, pause and linear ads for iOS, on the *Video Ads API & SDK v2* contract. Integration guide: https://docs.kontext.so/video/sdk/swift.
