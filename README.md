# Kontext Swift Video SDK

Overlay, pause and linear video ads for short-drama and other video-first iOS apps. The SDK asks the Kontext
ad server for ads for the episode the viewer watches, renders the creative before its moment, shows it in your
player or full screen, fires every beacon itself, and tells you what happens on screen through a delegate.

- Integration guide: [docs.kontext.so/video/sdk/swift](https://docs.kontext.so/video/sdk/swift)
- API reference: the DocC catalog in `Sources/KontextVideoSDK/KontextVideoSDK.docc` (Xcode: Product → Build
  Documentation)
- Changes: [CHANGELOG.md](CHANGELOG.md)

## Requirements

- iOS 14 or later
- Swift 5.9 (Xcode 16 or later)
- Swift Package Manager

## Installation

In Xcode: File → Add Package Dependencies, then `https://github.com/kontextso/sdk-swift-video.git`. Or in
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kontextso/sdk-swift-video.git", .upToNextMinor(from: "0.2.0")),
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "KontextVideoSDK", package: "sdk-swift-video")]),
    // optional, for a TTSDK player: .product(name: "KontextVideoTTSDK", package: "sdk-swift-video")
]
```

While the SDK is pre-1.0, a minor version may break: pin up to the next minor.

## A minimal integration

```swift
import KontextVideoSDK

// Once, at app launch.
KontextVideo.shared.initialize(with: .init(publisherToken: "yourapp-dev"))

// One VideoAds per episode, tracking the player it plays in.
let ads = VideoAds(content: .init(id: "series-1-ep-6", language: "en"))
ads.track(player)

// Before the moment: get the ad and render it, so show is instant.
let ad = try await ads.format(.pause)
try await ad.load()
ad.delegate = self   // a VideoAdDelegate: the impression, clicks, and exactly one didEnd

// At the moment.
player.pause()
try ad.show(in: playerView)   // show(from:) for a linear ad

// When the viewer leaves the episode.
ads.destroy()
```

In SwiftUI, `VideoAdHost` shows the ad you set over your player and reports through closures:

```swift
VideoPlayerView(player: player)
    .overlay {
        VideoAdHost(ad: model.ad, onEnd: { _, _ in model.ad = nil })
    }
```

Each episode's ads show only in that episode; at most one ad is on screen in the whole app. The guide covers
the three formats, the delegate, consent and App Tracking Transparency, and custom players. For a TTSDK
player, see [KontextVideoTTSDK](Sources/KontextVideoTTSDK/README.md).

## Good to know

A custom player passed to `VideoAds.track(_:)` is held strongly. If it references the `VideoAds` (or the object that owns it, such as your player model), the two keep each other alive until `destroy()`: call `destroy()` when the viewer leaves the video, or don't reference the ads from the adapter.

## License

See [LICENSE](LICENSE).
