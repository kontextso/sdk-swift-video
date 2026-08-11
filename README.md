# Kontext Video SDK

Swift SDK for integrating Kontext video ads into short-drama and other video-first iOS apps.

> **Status: early development.** The public API surface below is a working skeleton — ad rendering and the server endpoint are still being built with our design partners.

## Supported formats

| Format | Behavior |
|---|---|
| **Overlay Ad** | Requested at the start of the video, shown at the right moments — N per video |
| **Pause Ad** | Prepared upfront, shown instantly when the user pauses — 1 per video (v1) |
| **Full-Screen Swipe Banner** | Prepared before the swipe can happen; the app signals the moment — max 1 per video |

## Usage

```swift
import KontextVideoSDK

// 1. Initialize the SDK.
// installId (persistent) and sessionId (server-assigned) are managed
// automatically — you never have to touch them.
let session = KontextVideo.createSession(VideoSessionOptions(
    publisherToken: "pub-xxxx",
    userId: "user-123",
    userEmail: "jane@example.com",
    enabledFormats: [.overlay, .pauseAd, .swipeBanner],  // omit to enable all
    onEvent: { event in
        switch event {
        case .filled(let data): print("ad ready: \(data.format)")
        default: break
        }
    }
))

// 2. Attach your player so the SDK can render ads over it.
session.attachPlayer(playerView: playerView, player: avPlayer)

// 3. Tell the SDK a new video is loading. Returns the ads prepared for
// this video; overlay and pause ads show automatically.
let ads = session.startVideo(
    externalId: "ep-1042",                              // your video ID
    title: "Episode 42: The Betrayal",                  // optional if uploaded via API
    description: "Mia confronts Ethan about the letter" // optional if uploaded via API
)

// 4. Swipe banner only: the app signals the right moment.
ads.showSwipeBanner()
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
