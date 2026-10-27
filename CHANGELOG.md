# Changelog

## 0.1.0

Initial release: overlay, pause and linear ads for iOS, on the *Video Ads API & SDK v2* contract. Integration guide: https://docs.kontext.so/video/sdk/ios.

SKAdNetwork for app-install ads: the impression is registered with Apple while the ad is on screen, and a tap opens the App Store product sheet inside the app with the campaign's attribution. Nothing to call; the identifiers in `Info.plist` are the app's only part.
