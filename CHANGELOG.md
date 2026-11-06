# Changelog

## 0.2.0

In progress.

### Breaking
* `VideoAds.track(_:)` replaces `trackPlayhead(of:)` and `playheadProvider`. Pass an `AVPlayer`, or any player conformed to the new `ContentPlayer` protocol (`currentTime`, `isPlaying`, and optional `isPlayingPublisher`, `playbackSpeed`, `seekPublisher`, `contentChangedPublisher` and `currentItem`, the episode it plays, so an episode's ads are shown only in that episode). The SDK reads the playhead from it as before, and now also follows its playback. It holds an `AVPlayer` weakly, and `destroy()` or releasing the `VideoAds` drops every observer.
* An overlay lives only while the content plays, when a player is tracked:
  * The overlay ends as `.interrupted` when the content pauses (a published pause counts even if playback resumes before it is delivered), the item plays to its end (whatever `actionAtItemEnd` does; until the item plays again, the next overlay is refused), the player moves to another item, `track(_:)` is called with another player, or the tracked player is gone. A pause while the overlay's scene is not active, such as iOS pausing the player as the app goes to the background, freezes the overlay instead, and counts only if the content is still paused a second after the scene is active again.
  * The overlay's `duration` counts seconds of video while it is seen. A stall, or video played while its scene was inactive, counts nothing. An `AVPlayer`'s time jumps count nothing, and its own speed tells fast playback from a seek; a custom player tells both with `playbackSpeed` and `seekPublisher`, and otherwise a step faster than 4.25× real time is taken as a seek.
  * `show(in:)` on an overlay over paused content throws the new `VideoAdError.contentPaused`, and the ad stays ready. A pause while the overlay's view is being attached ends it before any impression.
  * Another ad's `show` first ends an overlay whose content stopped, so a pause ad shown right after `player.pause()` finds the screen free. `show` runs that app code (the overlay's `didEnd`, the player's `isPlaying`) before its own checks.
  * Without a tracked player, an overlay runs on its own time, as before.
* An episode's ads show only in that episode. A player belongs to one `VideoAds` at a time: `track(_:)` on another one lets go of it in the first, and the first one's overlay and pause ads then throw `invalidated(.contentChanged)` at `show`; so do they once the tracked `AVPlayer` plays another item than at `track`. Linear ads are not checked.
* `VideoAd.Click` no longer has `url`: `didClick` says where the viewer tapped (`area`), not what opened, as established ad SDKs do. The page's target was the advertiser's tracking link, often not what opened (a fallback, the App Store sheet), and the SDK opens it itself.
* `VideoAd.dismiss()` and `reject(_:)` no longer throw: drop the `try`. `dismiss()` on a linear ad is a programmer error (a debug build stops, a release build logs); `reject()` of an ad that was shown or already ended does nothing.
* `show(in:)` on a linear ad and `show(from:)` on an overlay or pause ad stop a debug build at the call; a release build throws `wrongShowMethod`.
* `VideoAdError.wrongPresentation` is now `wrongShowMethod`: the call (`show(in:)` or `show(from:)`) does not fit the ad's format.
* `VideoAdError.presenterUnavailable` is now `cannotShowNow`: nothing on screen can hold the ad now.
* Initialisms are cased as in Swift: `KontextVideo.variantID`, `VideoAds.lastRequestID`, `Regulatory.gppSID`. The wire keeps its names.
* `Content`, `User`, `Regulatory` and `AdFormat` are no longer `Codable` (`Content`, `User` and `Regulatory` are `Hashable` now): the wire form is the SDK's own.
* `Configuration.defaultAdServerURL` is no longer public; `adServerURL` is an optional `URL?`, `nil` for the production server.
* A destroyed `VideoAds`'s ads throw `VideoAdError.destroyed` only, never `invalidated(.destroyed)`.
* `VideoAdError.request` carries a `VideoAdError.RequestFailure` instead of an internal error: `offline` (no connection, the connection lost, the host unreachable), `timedOut`, `server(status:)` (an error status), or `badResponse` (an answer the SDK could not use). `VideoAdError` is `Equatable`, so `error == .request(.offline)` works in an app's tests. The underlying error stays in the SDK's console log.

### Added
* A COPPA request (`Regulatory(coppa: true)`) also leaves out the IDFV, besides the advertising id, the user id, the email and its hash; the install id stays.
* Every request, the SDK's own and beacons alike, follows at most 10 redirects (as the Kotlin SDK); beacons are sent by a `BeaconClient` of their own, out of `Tracker`.
* `VideoAdHost`, a SwiftUI view: set its `ad` to show a loaded ad (an overlay or pause ad where it is placed, a linear ad full screen), `nil` to dismiss it; `onEnd`, `onImpression`, `onClick`, `onShowFailed` replace the delegate.
* `KontextVideoTTSDK`, an optional product: `ads.track(ttVideoEngine:)` follows a TTSDK `TTVideoEngine`, read through its Objective-C properties, with no TTSDK dependency.
* `show(in:insets:)`: insets that keep an overlay or a pause card clear of your own controls, added to the view's safe area (`bottom: 80` puts a bottom strip 80 points above it). Kept through resizes and rotations, counted in `containerTooSmall`'s minimum; a full-screen pause ad ignores them. `show(in:)` is unchanged. Insets that leave no width or height throw `containerTooSmall` (or end a shown ad as `.interrupted` on a resize), however large.
* `VideoAds(content:labels:)`: key-values that say where the ads play, such as the viewer's stage in the series or the player's layout (`["stage": "first_episode", "layout": "fullscreen"]`). Every ads request of that `VideoAds` carries them (`labels`), fixed for its life; the server's configuration decides what they change, such as which formats it offers. They are a free format, sent as given: use the names and values Kontext gives you. The example app shows four situations this way, a full-screen pause ad among them.
* Error reports: when the server turns them on in `/config` (`reportErrors`), the SDK sends its faults (a failed request, a creative or frame page that broke, a presentation UIKit refused, an integration mistake) to `/v2/error`, as codes and ids, never personal data. New `VideoAds.lastRequestID`: quote it to Kontext when an ad or a no-fill looks wrong.
* `KontextVideo.shared.state` is public and read-only: readable at any time, for example to hide your ad UI once the server switched the SDK off.
* Public initializers for `VideoAd.Price` and `VideoAd.Click`, for your own tests.
* A `ContentPlayer` that leaves an optional member to its default (often one declared with another type) says so once on the console.
* A DocC catalog: the API reference builds with `xcodebuild docbuild`.

### Changed
* A click opens a web link in KontextKit's in-app browser over your app instead of Safari, unless an installed app claims the link (a universal link); an app's own link (`brandapp://…`) and an App Store link (`apps.apple.com`, `itunes.apple.com`, `itms-apps:`) still open that app, an app-install ad's signed click still opens the App Store sheet, and the fallback still opens when nothing opened the first. The AdChoices link opens the same way. Your app stays in front: an overlay or pause ad under the browser stays up, its duration, on-screen time and viewability paused until the viewer taps Done; a linear ad's video pauses and plays on after Done. The `click` beacon and `didClick` are unchanged.
* An ad whose `trigger` is a `window` (timed mode) is dropped and reported as malformed, as an unknown trigger kind is; its format answers as a no-fill unless another ad fills it. The SDK has no timed mode, and such an ad was shown at whatever moment the app chose.
* A video ad on screen that ended before its first frame fires the `close` beacon only when the app, an interruption, a destroy or its own time ended it, as the Kotlin SDK does; a skip or the page's own close no longer adds a second `close` after its `skip` or `close`, and an image ad never fires one in its impression's place.
* A page message may be up to 1 MB (was 64 KB).
* `show(in:)` into a view in its window with no part of it inside the window (a pager's neighbour page, a view scrolled away) throws `cannotShowNow`, and the ad stays ready, as in the Kotlin SDK; before, the show was accepted and the ad ended `.interrupted` at once, spent.
* An overlay or pause ad ends `.interrupted` when the app presents another view controller over the one holding its view, a sheet or form sheet included, as the Kotlin SDK ends one when another Activity covers the player's; before, only a full-screen cover ended it, and under a sheet its time kept counting. An alert, a popover and the App Store sheet of the ad's own click leave it up. `show(in:)` under such a presentation throws `cannotShowNow`, and the ad stays ready. A linear ad covered by a presentation still waits for it to go.
* `/config` is sent once, with no retry, like every other request; a retry policy comes later. After a failure the SDK is `.failed`, and the next `format()` tries `/config` again, as before.
* KontextKit 0.5.0, now up to the next minor version, so its patches arrive without an SDK release. The volume in an ads request comes from KontextKit again, which since 0.4.0 reads it without touching the app's audio session. The in-app browser a click opens is KontextKit's, with its close handler, since 0.5.0.
* An overlay's `duration` and its on-screen time count while its window's scene is active, not the app: on iPad, a second window of the app taking the screen freezes them too.
* Ads never play in Picture in Picture or on an AirPlay screen, where nothing could measure them.
* Privacy manifest: declares the system boot time API (35F9.1, for the on-screen clock and load times), video views (Product Interaction), coarse location and performance data; device facts sent as ad inputs (Other Data Types) are declared apart from error and debug reports (Other Diagnostic Data); device ids, ad data and diagnostics are linked (the install id joins them). Nothing is declared as tracking: no Kontext server uses the data for tracking yet. Publishers' App Store privacy labels should be checked against it.

### Fixed
* A linear ad ended while UIKit was still animating it onto the screen (a `destroy()`, a released `VideoAds`, a creative error right after `show(from:)`) is dismissed once that animation finishes; before, UIKit dropped the dismissal and a black full-screen controller stayed with no way to close it.
* An overlay or pause ad whose own box is wholly off screen where it is placed (a feed scrolled so the player's middle shows, not its top card) ends `.interrupted` at `show`, with no impression.
* A pause ad on screen ends `.interrupted` when another `VideoAds` takes its player (the next page of a feed that shares one player) or the player moves to another item; it no longer holds the app's slot over content it is not for.
* An overlay or pause ad out of sight for a second while its scene is active (a feed cell swiped away, a view moved off screen) ends `.interrupted` and frees the app's slot; `overlayViewDuration` and an overlay's `duration` count only time the ad is seen.
* `isReady` is `false` while the server has switched the SDK off, for every `VideoAds`.
* `load()` throws `creativeFailed(code:)` for a creative that failed, also when the page's error came right after `ad.loaded`; on an ad already shown it returns at once.
* The first `track(_:)` while an overlay is on screen leaves it there; only a player replacing another ends it.
* A page that ends itself after its video completed (`reason: complete`) leaves `isCompleted == true`.
* An ads request lists as `held` only the ads still unshown and valid when it leaves, not when it was started (before `/config` or the ATT dialog).
* The 10 s creative load timeout counts the active time that actually passed.
* `ad.exposure` tells the page `exposedPercentage` in 0–100, as MRAID's `exposureChange` does, not 0–1.
* No viewability verdict (`viewable`, `notViewable`, `viewUndetermined`) for an ad that never had an impression, such as a video overlay nobody started.
* Transparency multiplies along the view's ancestors, for `show` and for viewability: three ancestors at 0.1 leave the ad unseen.
* A click whose `url` is missing or unusable but whose `fallbackUrl` is good opens the fallback, as on Android.
* An end-card click on an ad without end-card click entries (an overlay or pause ad) fires the creative's `click` entries: every accepted click is counted.
* Error reports name an ad's invalidation as both SDKs do (`creativeFailed`, with `code` as its own key).
* An app-install ad whose SKAdNetwork start Apple refused now still sends Apple the matching end.
* A frame page whose connection drops after it started loading fails the ad at once (`didFail`), instead of waiting for the load timeout.
* Example app: leaving the player screen no longer restarts the content when `destroy()` ends an ad on screen.
* `track(_:)` after `destroy()` does nothing; a `track` or `destroy()` in an old player's subscription cancellation wins over the call that cancelled it, instead of crashing the app, and an overlay shown over the old player still ends; a player that played to its end and plays again without a seek still refuses an overlay.

## 0.1.0

Initial release: overlay, pause and linear ads for iOS, on the *Video Ads API & SDK v2* contract. Integration guide: https://docs.kontext.so/video/sdk/swift.
