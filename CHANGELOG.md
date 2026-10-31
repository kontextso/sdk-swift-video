# Changelog

## 0.2.0

In progress.

### Breaking
* `VideoAds.track(_:)` replaces `trackPlayhead(of:)` and `playheadProvider`. Pass an `AVPlayer`, or any player conformed to the new `VideoAdsPlayer` protocol (`currentTime`, `isPlaying`, and an optional `isPlayingPublisher`). The SDK reads the playhead from it as before, and now also follows its playback. It holds the player weakly, and `destroy()` or releasing the `VideoAds` drops every observer.
* An overlay lives only while the content plays, when a player is tracked:
  * The overlay ends as `.interrupted` when the content pauses (a published pause counts even if playback resumes before it is delivered), the item plays to its end (whatever `actionAtItemEnd` does; until the item plays again, the next overlay is refused), the player moves to another item, `track(_:)` is called with another player, or the tracked player is gone.
  * The overlay's `duration` counts seconds of video while it is seen. A stall, or video played while its scene was inactive, counts nothing. An `AVPlayer`'s time jumps count nothing, and its own speed tells fast playback from a seek; for other players a step faster than 4.25× real time is taken as a seek.
  * `show(in:)` on an overlay over paused content throws the new `VideoAdError.contentPaused`, and the ad stays ready. A pause while the overlay's view is being attached ends it before any impression.
  * Another ad's `show` first ends an overlay whose content stopped, so a pause ad shown right after `player.pause()` finds the screen free. `show` runs that app code (the overlay's `didEnd`, the player's `isPlaying`) before its own checks.
  * Without a tracked player, an overlay runs on its own time, as before.
* `VideoAd.Click` no longer has `url`: `didClick` says where the viewer tapped (`area`), not what opened, as established ad SDKs do. The page's target was the advertiser's tracking link, often not what opened (a fallback, the App Store sheet), and the SDK opens it itself.

* `show(in:insets:)`: insets that keep an overlay or a pause card clear of your own controls, added to the view's safe area (`bottom: 80` puts a bottom strip 80 points above it). Kept through resizes and rotations, counted in `containerTooSmall`'s minimum; a full-screen pause ad ignores them. `show(in:)` is unchanged. Insets that leave no width or height throw `containerTooSmall` (or end a shown ad as `.interrupted` on a resize), however large.
* `VideoAds(content:labels:)`: key-values that say where the ads play, such as the viewer's stage in the series or the player's layout (`["stage": "first_episode", "layout": "fullscreen"]`). Every ads request of that `VideoAds` carries them (`labels`), fixed for its life; the server's configuration decides what they change, such as which formats it offers. Keys of `a-z`, `0-9` and `_`, values not empty, both at most 64 bytes, at most 20 pairs; the rest is dropped with a console warning. The example app shows four situations this way, a full-screen pause ad among them.
* Error reports: when the server turns them on in `/config` (`reportErrors`), the SDK sends its faults (a failed request, a creative or frame page that broke, a presentation UIKit refused, an integration mistake) to `/v2/error`, as codes and ids, never personal data. New `VideoAds.lastRequestId`: quote it to Kontext when an ad or a no-fill looks wrong.
* `/config` is sent once, with no retry, like every other request; a retry policy comes later. After a failure the SDK is `.failed`, and the next `format()` tries `/config` again, as before.
* KontextKit 0.4.0. The volume in an ads request comes from KontextKit again, which since 0.4.0 reads it without touching the app's audio session. An app-install ad whose SKAdNetwork start Apple refused now still sends Apple the matching end.
* An overlay's `duration` and its on-screen time count while its window's scene is active, not the app: on iPad, a second window of the app taking the screen freezes them too.
* Ads never play in Picture in Picture or on an AirPlay screen, where nothing could measure them.
* A frame page whose connection drops after it started loading fails the ad at once (`didFail`), instead of waiting for the load timeout.
* Example app: leaving the player screen no longer restarts the content when `destroy()` ends an ad on screen.
* Privacy manifest: declares the system boot time API (35F9.1, for the on-screen clock and load times), video views (Product Interaction), coarse location and performance data; device facts sent as ad inputs (Other Data Types) are declared apart from error and debug reports (Other Diagnostic Data); device ids, ad data and diagnostics are linked (the install id joins them). Nothing is declared as tracking: no Kontext server uses the data for tracking yet. Publishers' App Store privacy labels should be checked against it.

## 0.1.0

Initial release: overlay, pause and linear ads for iOS, on the *Video Ads API & SDK v2* contract. Integration guide: https://docs.kontext.so/video/sdk/swift.
