# Kontext Video SDK

Swift SDK for integrating Kontext video ads into short-drama and other video-first iOS apps.

> **Status: early development.** Pause ads render natively; the server endpoint is being designed with our design partners against a [mock server](https://github.com/kontextso/sdk-video-mock-server).

## Supported formats

| Format | Behavior |
|---|---|
| **Pause overlay** (`pauseOverlay`) | Image banner at the top (or bottom) of the paused player; the content stays visible |
| **Pause fullscreen** (`pauseFullscreen`) | Image over the whole paused player with a styleable Resume button |

Both are prepared at video start; the app shows one when the user pauses and hides it on resume. Each ad is shown once.

Overlay ads and the full-screen swipe banner are planned and will be added later.

## Pause ads

The pause ad follows the **Pause** format of the IAB Tech Lab
[CTV Ad Portfolio](https://github.com/InteractiveAdvertisingBureau/Ad-Format-Guidelines-for-Digital-Video-CTV)
(Ad Format Guidelines for Digital Video and CTV v2.0, § Pause Ad Format Guidelines):

| Property | Guideline |
|---|---|
| Initiation | Viewer initiated: the program is paused by the viewer |
| Creative type | Display / static, or video / animated |
| Creative size | Fullscreen: 1920 × 1080 · Partial screen: 600 × 600 |
| Aspect ratio | Fullscreen: 16:9 · Partial screen: 1:1 |
| File | Static creatives under 350 kB (see the IAB video submission guidelines for video) |
| Sound | Not required by default |
| Placement | Fullscreen or partial screen within the pause experience |
| Interactive components | Optional: QR codes, remote-control interactivity (SIMID) |
| Duration & exit | Ends when the viewer dismisses the ad, resumes content, exits the app, or the device times out / starts its screensaver. Some pause ads refresh, others stay for the whole pause. Video may autoplay; refresh and autoplay behavior is signaled by the seller. |

In OpenRTB terms the placement is `imp.video` with `plcmt = 5` (Pause), `pos = 7`
(fullscreen) or `8` (partial screen), and `playbackmethod = 8` / `9` (sound on / off);
the response is a VAST 4.2 `<NonLinearAds>` creative with `creativeView`,
`overlayViewDuration` and `close` tracking.

The spec is written for 16:9 TV screens and has no portrait size. The SDK
maps the two IAB placements to its two formats: `pos = 8` (partial screen) →
`pauseOverlay`, an image banner sized from the creative's declared dimensions
so vertical creatives work too; `pos = 7` (fullscreen) → `pauseFullscreen`,
the image over the whole player with a Resume button (the SDK emits `.closed`
when it is tapped, then calls your `onResume`).

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

// 2. Tell the SDK which video is current, then load ads for it.
let ads = session.setVideo(
    externalId: "ep-1042",                              // your video ID
    title: "Episode 42: The Betrayal",                  // optional if uploaded via API
    description: "Mia confronts Ethan about the letter" // optional if uploaded via API
)
ads.load(formats: [.pauseOverlay, .pauseFullscreen])    // one request for exactly these formats

// 3. You control the player, so you tell the SDK when to show and hide.
//    One placement object per format; each ad is shown once, then
//    `isReady` is false again.
func didPause() {
    if ads.pauseFullscreen.isReady {
        var style = PauseFullscreenAd.Style()
        style.resumeTitle = "Continue watching"
        ads.pauseFullscreen.show(in: playerView, style: style) { avPlayer.play() }
    } else if ads.pauseOverlay.isReady {
        var style = PauseOverlayAd.Style()        // margins, maxWidth, cornerRadius, placeholderColor
        style.margins.top = 24
        ads.pauseOverlay.show(in: playerView, position: .top, style: style)
    }
}

func didResume() {
    ads.pauseOverlay.hide()
    ads.pauseFullscreen.hide()
    ads.pauseOverlay.load()                    // prepare the next pause (server decides whether to fill)
}

// 4. Leaving the player: release the ads. Takes ~1 s when an ad was on
//    screen (measurement beacons); `setVideo` for the next video does
//    this for you.
func didLeavePlayer() async {
    await ads.destroy()
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
