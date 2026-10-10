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

KontextVideo.shared.initialize(with: .init(publisherToken: "yourpublisher-dev"))
```

Use your developer token (`{publisher}-dev`) while testing and your production token in release builds. If you want to
know when the SDK is ready, await the call from `async` code, or pass a completion:

```swift
let state = await KontextVideo.shared.initialize(with: configuration)   // .enabled, .disabled(reason:) or .failed

KontextVideo.shared.initialize(with: configuration) { state in … }
```

All options, with their defaults. The SDK's model types are nested in `KontextVideo` (`KontextVideo.Configuration`,
`.User`, `.Content`, `.Player`), as `UIButton.Configuration`, so they never collide with your app's own `User` or
`Player`; where Swift can infer the type, `.init(…)` is enough.

```swift
KontextVideo.Configuration(
    publisherToken: "yourpublisher-dev",
    requestTrackingAuthorization: false,       // let the SDK show the ATT dialog
    logLevel: .warning,                        // .none, .error, .warning, .info, .debug
    adServerURL: KontextVideo.Configuration.defaultAdServerURL   // override only for a staging or mock server
)
```

What you know about the viewer usually arrives later: the user after login, consent when your consent platform
has it. Set these on the shared instance whenever you learn them, from anywhere; the next ads request carries
them, and ads already loaded but not shown are discarded. `nil` clears a value.

```swift
KontextVideo.shared.user = .init(id: "u_84213907", email: "ryan@example.com", yearOfBirth: 1994)
KontextVideo.shared.regulatory = .init(coppa: false)        // the rest is read from your CMP's storage
KontextVideo.shared.variantId = "experiment-b"              // A/B testing, agreed with Kontext
```

### 2. Initialize the player

`KontextVideo.Player` represents your video player: the area the ads will be shown in, in points,
whether it is full screen, and where the content is. Keep it current: set `playhead` as the content plays, and
`width`, `height` and `fullscreen` when the layout changes, for example on rotation. For a prefetch before the
player exists, start with the size it will most likely have.

> **Temporary.** `Player` will become a handle to your actual player, from which the SDK reads these values itself.

```swift
let player = KontextVideo.Player(width: 393, height: 852, fullscreen: true)

player.playhead = 12_000       // milliseconds in content time; update it as the content plays
player.fullscreen = false      // and the box when the layout changes
```

### 3. Create the ads for a video

One `VideoAds` per video. Create it as early as you like, for example for the next episode while the current one
plays. `KontextVideo.Content` describes the video ("content" is the ad-industry word for it): `id` is your own id, in
any scheme; everything else is optional context that helps targeting.

```swift
let ads = VideoAds(
    content: .init(
        id: "100001-6",
        language: "en",
        title: "Episode 6",
        duration: 92_000,            // milliseconds
        episodeNumber: 6,
        genre: "romance",
        series: .init(id: "100001", title: "My Marionette Lover", episodeCount: 40)
    ),
    player: player
)
```

### 4. Placements and loading the ads

A placement is a piece of your inventory, created in the Kontext dashboard with a format and an id you chose
(`episode-midroll`, `fullscreen-pause`); demand, floors, frequency caps and reporting are configured there. Every
publisher starts with one per format: `overlay`, `pause`, `interstitial`.

Get the placement object once from `ads` and keep it; the format in the call must match the dashboard. Every load
is one request for that placement, with the options of its format; one ad per placement at a time. Loads started
while the SDK is still initialising wait for it; nothing is requested before `/init` has succeeded.

```swift
let overlay = ads.overlayPlacement("overlay")
let pause = ads.pausePlacement("pause")
let midroll = ads.interstitialPlacement("interstitial")

// A strip across the player while the content plays.
overlay.load(OverlayOptions(
    positions: [.bottom]             // where you can render it; default: top and bottom
))

// A card, or the full player, while the content is paused.
pause.load(PauseOptions(
    positions: [.top, .fullscreen]   // what you can render; default: top and bottom
))

// A full-screen video at a moment you pick.
midroll.load(InterstitialOptions(
    timing: .preroll,                // where you will show it; default: .midroll
    maxDuration: 30_000,             // milliseconds
    muted: false,                    // start with the sound off; default: false
    rewarded: false                  // non-skippable, with a reward granted when the video completes
))
```

Every option is optional: `overlay.load()` asks with the defaults.

### 5. Release them

When the viewer leaves the video. Nothing destroys a `VideoAds` for you, so destroy the previous episode's when
you move on.

```swift
ads.destroy()
```

## License

Apache 2.0, see [LICENSE](LICENSE).
