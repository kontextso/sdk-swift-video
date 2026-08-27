# Kontext Video SDK

Swift SDK for integrating Kontext video ads into short-drama and other video-first iOS apps.

> **Status: early development.** Pause ads render natively; the server endpoint is being designed with our design partners against a [mock server](https://github.com/kontextso/sdk-video-mock-server).

## Supported formats

| Format | Behavior |
|---|---|
| **Pause Ad** | Prepared upfront; the app shows it when the user pauses and hides it on resume — 1 per video (v1) |

Overlay ads and the full-screen swipe banner are planned and will be added later.

## Usage

```swift
import KontextVideoSDK

// 1. Initialize the SDK.
let session = KontextVideo.createSession(VideoSessionOptions(
    publisherToken: "pub-xxxx",
    userId: "user-123",
    userEmail: "jane@example.com",
    onEvent: { event in
        switch event {
        case .filled(let data): print("ad ready: \(data.format)")
        default: break
        }
    }
))

// 2. Tell the SDK a new video is loading. Returns the ads prepared for
// this video.
let ads = session.startVideo(
    externalId: "ep-1042",                              // your video ID
    title: "Episode 42: The Betrayal",                  // optional if uploaded via API
    description: "Mia confronts Ethan about the letter" // optional if uploaded via API
)

// 3. You control the player, so you tell the SDK when to show and hide.
func didPause() {
    ads.showPauseAd(in: playerView) { avPlayer.play() }  // Resume button tapped
}

func didResume() {
    ads.hidePauseAd()
}

```

## Installation

### Swift Package Manager

```swift
.package(url: "https://github.com/kontextso/sdk-swift-video.git", from: "0.1.0")
```

### CocoaPods

```ruby
pod 'KontextVideoSDK'
```

## Example app

`Example/` contains a minimal short-drama app that links the SDK:

- **Home screen** — a grid of story cards.
- **Player** — tapping a story opens a fullscreen vertical video feed; swipe up/down to move between episodes, tap to play/pause.

Every episode plays the same bundled portrait (9:16) sample clip (`Example/Example/Resources/sample-episode.mp4`, free stock footage from [Mixkit](https://mixkit.co)) — no network needed.

### Running

Requires Xcode 16+ and an iOS 17+ simulator.

```bash
cd Example
open Example.xcodeproj
```

Then run the `Example` scheme. The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `Example/project.yml` (`xcodegen generate` after structural changes).

For CI/screenshot automation, launching with the `AUTO_OPEN_STORY` environment variable set jumps straight into the player:

```bash
SIMCTL_CHILD_AUTO_OPEN_STORY=1 xcrun simctl launch booted so.kontext.example-video
```

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for building and testing the SDK, and [RELEASING.md](RELEASING.md) for cutting a release.

## License

Apache 2.0 — see [LICENSE](LICENSE).
