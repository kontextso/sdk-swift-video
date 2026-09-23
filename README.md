# Kontext Video SDK

Swift SDK for integrating Kontext video ads into short-drama and other video-first iOS apps.

> **Status: early development.** All three formats render natively; the server endpoint is being designed with our design partners against a [mock server](https://github.com/kontextso/sdk-video-mock-server).

## Supported formats

| Format | Behavior |
|---|---|
| **Pause** (`pause`) | Image banner at the top (or bottom) of the paused player; the content stays visible |
| **Interstitial** (`interstitial`) | Full-screen video the SDK presents at a moment the app chooses; closable after the server's `skip_after_ms`, and after the video ends the last frame stays up until the viewer taps Close |
| **Overlay** (`overlay`) | Image banners while the episode plays — several per video, each in a window the server derived from the scene; the SDK tells you when a window opens, you decide to show |

All are prepared at video start; the app shows a pause ad when the user pauses and hides it on resume, shows overlays in their windows, and presents the interstitial at a moment it picks (a scene break, the end of an episode). Each ad is shown once.

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

### Tracking

The ad server sends nine tracking URLs per ad (`tracking` in the JSON, the same set
it puts into VAST). The SDK fires them, each at most once per ad:

| When | Fired |
|---|---|
| the creative image is painted | `impression`, `creative_view` |
| ≥ 50 % of the ad on screen for 1 continuous second (MRC display rule), app active | `viewable` — or `not_viewable` if hidden before that |
| tap | opens `click_through` in an in-app browser (`/impression/{bid}/redirect` records the click, then forwards) |
| hide, for any reason | `overlay_view_duration`, plus `close` when the user dismissed (Resume) |
| interstitial video: first frame, 25 / 50 / 75 %, end, closed early | `video.start`, `video.first_quartile` / `midpoint` / `third_quartile`, `video.complete`, `video.skip` (`/impression/{bid}/vast?event=…`) |

Pings are `POST`s. `[CACHEBUSTING]` is replaced per fire, `[TIMESTAMP]` with the
current ISO-8601 time, any other `[MACRO]` becomes empty.

The spec is written for 16:9 TV screens and has no portrait size. The SDK
maps the two IAB placements to its two formats: `pos = 8` (partial screen) →
`pause` (`INSTREAM_IMAGE_PAUSE`), an image banner sized from the creative's
declared dimensions so vertical creatives work too. (A fullscreen pause
variant existed in the prototype and was dropped 2026-08-31.)

## Usage

> The `container` you pass to `show(in:)` is any `UIView`; the SDK mounts
> the ad as a subview and never assumes an `AVPlayer`. Pass the view that
> fills and clips the video area — an `AVPlayerLayer` host view, or a
> third-party player's view such as SJVideoPlayer's `player.view` (the
> player StoReel ships) — not the outer view controller's view, so the
> ad's insets land on the video.

```swift
import KontextVideoSDK

// 1. Initialize the SDK.
let session = KontextVideo.createSession(VideoSessionOptions(
    publisherToken: "pub-xxxx",
    userId: "user-123",
    userEmail: "jane@example.com",
    onEvent: { event in
        if case .loaded(let d) = event {
            for r in d.results {
                for ad in r.ads { print("ready:", r.format, ad.id, "eCPM", ad.ecpm) }
            }
        }
    }
))

// 2. Tell the SDK which video is current, then load ads for it.
//    `id` is YOUR unique id for the video — any scheme (series id + number,
//    a UUID, …). Everything else is optional contextual signal: for short
//    drama the synopsis/keywords/rating usually live on the series.
let ads = session.setVideo(
    id: "100001-6",
    duration: 92,                                       // seconds
    language: "en",                                     // the track being played
    episodeNumber: 6,
    series: VideoSeries(
        id: "100001",
        title: "My Marionette Lover",
        description: "To win a bet with his friends, Ryan…",
        keywords: ["forced love", "fantasy"],
        contentRating: "18+",
        languages: ["en", "es"],
        episodeCount: 40
    )
)
ads.load(formats: [.pause, .interstitial, .overlay])    // one request for exactly these formats

// 3. You control the player, so you tell the SDK when to show and hide.
//    One placement object per format; each ad is shown once, then
//    `isReady` is false again. The ad shows immediately on pause.
//    Every ad carries `ecpm` (USD per 1,000 impressions) before it is
//    shown — rank it against your other demand and skip `show` if it loses.
func didPause() {
    if ads.pause.isReady, let ad = ads.pause.pending.first, ad.ecpm >= myFloor {
        var style = PauseAd.Style()               // margins, maxWidth, cornerRadius, placeholderColor
        style.margins.top = 24
        ads.pause.show(in: playerView, position: .top, style: style)
    }
}

func didResume() {
    ads.pause.hide()
    ads.pause.load()                           // prepare the next pause (server decides whether to fill)
}

// 4. Interstitial: a full-screen video the SDK presents itself, at a
//    moment you choose (3 s into the episode, a scene break, the end of
//    an episode). Pause your content first and resume it in `onDismissed`,
//    which runs once when the screen goes away: the viewer tapped Close
//    (after the server's `skip_after_ms`, or after the video ended — the
//    last frame stays up like a MAX end card), media failed, or your `hide()`.
func didReachAdMoment() {
    if ads.interstitial.isReady {
        player.pause()
        ads.interstitial.show(from: viewController) { player.play() }
    }
}

// 5. Overlay, windowed mode (we know your content): feed the playhead; the
//    SDK calls back when a scene window opens or closes. Showing is your call.
ads.overlay.onWindowOpen  = { ad in
    var style = OverlayAd.Style()             // same BannerStyle as the pause ad:
    style.margins.bottom = 96                 // margins, maxWidth, cornerRadius, placeholderColor
    ads.overlay.show(in: playerView, style: style)   // position defaults to the server's hint
}
ads.overlay.onWindowClose = { ad in ads.overlay.hide() }
player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { t in
    ads.overlay.playhead = t.seconds
}

//    Overlay, manual mode (we never saw your content, so there are no
//    windows — the ads come with `trigger.kind == "manual"`): decide the
//    moment yourself, exactly like the pause ad.
if ads.overlay.isReady { ads.overlay.show(in: playerView) }
ads.overlay.hide()

// 6. Leaving the player: release the ads. Takes ~1 s when an ad was on
//    screen (measurement beacons); `setVideo` for the next video does
//    this for you.
func didLeavePlayer() async {
    await ads.destroy()
}

```

All lifecycle events and their payloads are documented in
[EVENTS.md](EVENTS.md).

## Installation

Add Kontext's SKAdNetwork identifier (and any DSP ids from onboarding) to your
app's `Info.plist` so installs from directly-served campaigns are attributed —
the SDK reports them at session start via `/init`:

```xml
<key>SKAdNetworkItems</key>
<array>
  <dict><key>SKAdNetworkIdentifier</key><string>mp7rpxwdrx.adattributionkit</string></dict>
</array>
```


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
