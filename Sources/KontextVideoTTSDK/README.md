# KontextVideoTTSDK

An optional product for apps that play content with TTSDK (`TTVideoEngine`, the BytePlus / Volcengine VOD player)
instead of `AVPlayer`. One call replaces a hand-written `VideoAdsPlayer` wrapper:

```swift
import KontextVideoTTSDK

ads.track(ttVideoEngine: engine)                         // the page's engine
ads.track(ttVideoEngine: engine) { episode.id }          // and the episode it plays, for the content check
```

- **No TTSDK dependency.** TTSDK ships as a CocoaPod, which a Swift package cannot depend on. The adapter reads
  the engine by its Objective-C properties (`currentPlaybackTime`, `playbackState`, `playbackSpeed`), so this
  product builds without TTSDK and works with the app's own, licensed copy.
- **The app's delegate stays.** TTSDK has one `delegate`; the adapter never sets it. The SDK reads the engine
  four times a second while an overlay or pause ad is on screen, and at every `show`.
- **Playing** is TTSDK's playback state: paused or stopped is not playing; buffering is.
- **Which episode:** pass `currentItem` (the vid, the URL). An overlay or pause ad of this `VideoAds` then throws
  `invalidated(.contentChanged)` at `show` once it differs from the one at `track`.
- **Feeds:** track each page's engine with that page's `VideoAds` when the page becomes current.
- An object that is not a `TTVideoEngine` is followed as never playing, with an error on the console.

The Android SDK has the same adapter as `so.kontext:video-ttsdk`.
