# Kontext Video SDK for iOS

Swift SDK for Kontext video ads in short-drama and other video-first apps. In development; the contract it
implements is the *Video Ads API & SDK v2* document. iOS 14 and later.

```
Sources/KontextVideoSDK   the SDK (Swift package)
Example                   a minimal app that links it (xcodegen generate && open Example.xcodeproj)
```

The SDK builds on [KontextKit](https://github.com/kontextso/kontextkit-ios). What KontextKit should add in its next
release, and where this SDK works around it for now, is in [KontextKit-v2-updates.md](KontextKit-v2-updates.md).

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/kontextso/sdk-swift-video.git", from: "0.1.0")
```

## Usage

### 1. Initialize the SDK

Once, at app launch. The SDK contacts the ad server in the background; nothing is requested before that call has
succeeded.

```swift
import KontextVideoSDK

KontextVideo.shared.initialize(with: Configuration(publisherToken: "yourpublisher-dev"))
```

Use your developer token (`{publisher}-dev`) while testing and your production token in release builds. The optional
completion tells you when the SDK is ready:

```swift
KontextVideo.shared.initialize(with: configuration) { state in
    // .enabled, .disabled(reason:) or .failed
}
```

All options, with their defaults:

```swift
Configuration(
    publisherToken: "yourpublisher-dev",
    requestTrackingAuthorization: false,       // let the SDK show the ATT dialog
    logLevel: .warning,                        // .none, .error, .warning, .info, .debug
    adServerUrl: Constants.defaultAdServerUrl  // override only for a staging or mock server
)
```

What you know about the viewer usually arrives later: the user after login, consent when your consent platform
has it. Set these on the shared instance whenever you learn them, from anywhere; the next ads request carries
them, and ads already loaded but not shown are discarded. `nil` clears a value.

```swift
KontextVideo.shared.user = User(id: "u_84213907", email: "ryan@example.com", yearOfBirth: 1994)
KontextVideo.shared.regulatory = Regulatory(coppa: false)   // the rest is read from your CMP's storage
KontextVideo.shared.variantId = "experiment-b"              // A/B testing, agreed with Kontext
```

### 2. Initialize the player

`Player` is the interface that represents your video player: the area the ads will be shown in, in points,
whether it is full screen, and where the content is. Keep it current: set `playhead` as the content plays, and
`width`, `height` and `fullscreen` when the layout changes, for example on rotation. For a prefetch before the
player exists, start with the size it will most likely have.

> **Temporary.** `Player` will become a handle to your actual player, from which the SDK reads these values itself.

```swift
let player = Player(width: 393, height: 852, fullscreen: true)

player.playhead = 12_000       // milliseconds in content time; update it as the content plays
player.fullscreen = false      // and the box when the layout changes
```

### 3. Create the ads for a video

One `VideoAds` per video. Create it as early as you like, for example for the next episode while the current one
plays. `id` is your own id of the video, in any scheme; everything else is optional context that helps targeting.

```swift
let ads = KontextVideo.shared.createVideoAds(
    for: Video(
        id: "100001-6",
        language: "en",
        title: "Episode 6",
        duration: 92_000,            // milliseconds
        episodeNumber: 6,
        genre: "romance",
        series: Series(id: "100001", title: "My Marionette Lover", episodeCount: 40)
    ),
    player: player
)
```

### 4. Load the ads

One placement per format on `ads`: `overlay`, `pause` and `interstitial`. Load each one you will show; every
load is one request, with the options of its format. Loads started while the SDK is still initialising wait for
it; nothing is requested before `/init` has succeeded.

```swift
// A strip across the player while the content plays.
ads.overlay.load(OverlayOptions(
    positions: [.bottom]             // where you can render it; default: top and bottom
))

// A card, or the full player, while the content is paused.
ads.pause.load(PauseOptions(
    positions: [.top, .fullscreen]   // what you can render; default: top and bottom
))

// A full-screen video at a moment you pick.
ads.interstitial.load(InterstitialOptions(
    timing: .preroll,                // where you will show it; default: .midroll
    maxDuration: 30_000,             // milliseconds
    muted: false,                    // start with the sound off; default: false
    rewarded: false                  // non-skippable, with a reward granted when the video completes
))
```

Every option is optional: `ads.overlay.load()` asks with the defaults.

### 5. Release them

When the viewer leaves the video. Nothing destroys a `VideoAds` for you, so destroy the previous episode's when
you move on.

```swift
ads.destroy()
```

## License

Apache 2.0, see [LICENSE](LICENSE).
