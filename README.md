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
    user: User(id: "u_84213907", email: "ryan@example.com"),  // what you know about the viewer
    variantId: nil,                                           // A/B testing, agreed with Kontext
    regulatory: Regulatory(coppa: false),                     // consent signals; the rest is read from your CMP
    requestTrackingAuthorization: false,                      // let the SDK show the ATT dialog
    logLevel: .warning,                                       // .none, .error, .warning, .info, .debug
    adServerUrl: Constants.defaultAdServerUrl                 // override only for a staging or mock server
)
```

### 2. Create the ads for a video

One `VideoAds` per video. Create it as early as you like, for example for the next episode while the current one
plays. `id` is your own id of the video, in any scheme; everything else is optional context that helps targeting.

```swift
let ads = KontextVideo.shared.createVideoAds(for: Video(
    id: "100001-6",
    language: "en",
    title: "Episode 6",
    duration: 92_000,            // milliseconds
    episodeNumber: 6,
    genre: "romance",
    series: Series(id: "100001", title: "My Marionette Lover", episodeCount: 40)
))
```

### 3. Release them

When the viewer leaves the video. Nothing destroys a `VideoAds` for you, so destroy the previous episode's when
you move on.

```swift
ads.destroy()
```

## License

Apache 2.0, see [LICENSE](LICENSE).
