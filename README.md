# Kontext Video SDK for iOS

Swift SDK for Kontext video ads in short-drama and other video-first apps. In development; the contract it
implements is the *Video Ads API & SDK v2* document. iOS 14 and later.

```
Sources/KontextVideoSDK   the SDK (Swift package)
Example                   an app with a real AVPlayer that links it (xcodegen generate && open Example.xcodeproj)
```

Contributing: [DEVELOPMENT.md](DEVELOPMENT.md). Releases: [RELEASING.md](RELEASING.md), [CHANGELOG.md](CHANGELOG.md).

The SDK builds on [KontextKit](https://github.com/kontextso/kontextkit-ios). What KontextKit should add in its next
release, and where this SDK works around it for now, is in [KontextKit-v2-updates.md](KontextKit-v2-updates.md).

## Requirements

iOS 14 or later, Swift 5.9 (Xcode 15.0+). The SDK is UIKit-based; SwiftUI apps host their player in a
`UIViewRepresentable`, as the example does.

## Installation

Swift Package Manager, in Xcode (File → Add Package Dependencies) or in `Package.swift`:

```swift
.package(url: "https://github.com/kontextso/sdk-swift-video.git", from: "0.1.0")
```

CocoaPods:

```ruby
pod 'KontextVideoSDK', '~> 0.1'
```

The SDK ships a privacy manifest. If you let it show the App Tracking Transparency dialog
(`requestTrackingAuthorization: true`), add `NSUserTrackingUsageDescription` to your Info.plist.

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
`.User`, `.Content`), as `UIButton.Configuration`, so they never collide with your app's own `User` or `Content`;
where Swift can infer the type, `.init(…)` is enough.

```swift
KontextVideo.Configuration(
    publisherToken: "yourpublisher-dev",
    requestTrackingAuthorization: false,       // let the SDK show the ATT dialog before the first ads request
                                               // (needs NSUserTrackingUsageDescription in your Info.plist)
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
                                                            // (IABTCF_*, IABGPP_*, IABUSPrivacy_String); what you set wins
KontextVideo.shared.variantId = "experiment-b"              // A/B testing, agreed with Kontext
```

### 2. The player area and the playhead

There is no player object to conform or wrap. The SDK needs two facts about your player and takes each where it is
cheapest: the player's size, given once when you create the `VideoAds` (nothing for a full-screen player, the usual
case), and the content playhead, which the SDK *reads* when it needs one (at a request, in beacon macros) rather than
having you push it. For an `AVPlayer`, `trackPlayhead(of:)` is the whole integration; for any other player set a
closure. The view the ad goes into is passed at `show(in:)`. This is Google IMA's model (`IMAContentPlayhead`,
`IMAAVPlayerContentPlayhead`), without the protocol.

```swift
let ads = VideoAds(content: content)                                        // full screen
let ads = VideoAds(content: content, playerSize: CGSize(width: 390, height: 220))   // or the size in points

ads.trackPlayhead(of: avPlayer)                   // AVPlayer: the SDK reads currentTime() itself, holds the player weakly
ads.playheadProvider = { myPlayer.currentTime }   // any other player: seconds

try ad.show(in: playerView)                       // the view the content plays in (see 5)
```

Attach the playhead any time, before or after loading: a request made before the player exists carries content time
0, which is what a prefetch should say. With one `AVPlayer` reused across episodes (`replaceCurrentItem`), call
`trackPlayhead(of:)` when the episode starts playing in it, not when you create the `VideoAds`, or the next
episode's prefetch would carry the previous episode's time.

### 3. Create the ads for a video

One `VideoAds` per video. Create it as early as you like, for example for the next episode while the current one
plays; any number can be alive at once. `KontextVideo.Content` describes the video ("content" is the ad-industry
word for it): `id` is your own id, in any scheme; everything else is optional context that helps targeting. Times
are seconds. Leave `mediaRating` unset when you do not know it; the SDK never guesses.

When the viewer moves on to the next episode, `destroy()` the previous episode's `VideoAds` (see 7): an ad of it
still on screen ends with `didEnd(.destroyed)`, so nothing of episode 5 sits over episode 6.

```swift
let ads = VideoAds(content: .init(
    id: "100001-6",
    language: "en",
    title: "Episode 6",
    duration: 92,                // seconds
    episodeNumber: 6,
    genre: "romance",
    mediaRating: .safe,          // optional; unset = unknown
    series: .init(id: "100001", title: "My Marionette Lover", episodeCount: 40)
))

ads.trackPlayhead(of: avPlayer)  // when the episode starts playing
```

### 4. Placements and loading the ads

A placement is a piece of your inventory, created in the Kontext dashboard with a format and an id you chose
(`episode-midroll`, `fullscreen-pause`); demand, floors, frequency caps and reporting are configured there. Every
publisher starts with one per format: `overlay`, `pause`, `interstitial`.

Get the placement object once from `ads` and keep it; the format in the call must match the dashboard. `load` is
`async` and returns the ad, or throws: no fill, a failed request, a busy placement, an SDK that is not ready. You own
the ad you get; keep a reference until it is shown, drop it and it is gone. One *unshown* ad per placement at a
time: a second `load` while one is loading or waiting to be shown throws `.placementBusy`, but a `load` while the
previous ad is on screen is fine, so the next one is ready the moment the current one ends. Loads started while the
SDK is still initialising wait for it; after a failed `/init`, every `load` retries it first.

```swift
let overlay = ads.overlayPlacement("overlay")
let pause = ads.pausePlacement("pause")
let midroll = ads.interstitialPlacement("interstitial")

// A strip across the player while the content plays.
let strip = try await overlay.load(OverlayOptions(
    positions: [.bottom]             // where you can render it; default: top and bottom
))

// A card, or the full player, while the content is paused.
let card = try await pause.load(PauseOptions(
    positions: [.top, .fullscreen]   // what you can render; default: top and bottom
))
card.price.value                     // your own auction, if you run one
card.expirationDate                  // a Date

// A full-screen video at a moment you pick.
let interstitial = try await midroll.load(InterstitialOptions(
    timing: .preroll,                // where you will show it; default: .midroll
    maxDuration: 30,                 // seconds
    muted: false,                    // start with the sound off; default: false
    rewarded: false                  // non-skippable, with a reward granted when the video completes
))

// Every option is optional
let ad = try await overlay.load()

// Deciding before rendering (an app that runs its own auction): fetch the answer, load the winner
let bid = try await pause.fetch()                   // price, expirationDate, size…; nothing rendered yet
guard myAuction.accepts(bid.price) else { return }  // dropping a bid costs nothing
let ad = try await bid.load()                       // renders; the same VideoAd that load() returns

// No fill and failures are errors
do {
    let ad = try await pause.load()
} catch VideoAdError.noFill(let reason) {
    // nothing to show; reason: noAdMatch, frequencyCap, …
} catch VideoAdError.invalidPlacement(let problem) {
    // an integration bug: unknown id or wrong format; fix the id or the dashboard
} catch {
    // .placementBusy, .notInitialized, .initializationFailed, .disabled(reason:), .destroyed,
    // .creativeFailed(code:), .request(error), CancellationError
}
```

### 5. Show it, listen, dismiss

Overlay and pause ads are shown with `show(in:)`, inside the view your content plays in: the one holding the
`AVPlayerLayer`, or `contentOverlayView` of an `AVPlayerViewController`, or a `UIViewRepresentable`-hosted view in
SwiftUI. The SDK places its own view in it at the ad's position and size (a full-screen pause ad fills it);
`dismiss()` ends a pause ad when your content resumes. An overlay ends by itself when its `duration` elapses
(`didEnd(.completed)`); `dismiss()` is for ending it earlier (the content ended, a seek). `show` throws when
presentation cannot begin (nothing fired):
`.alreadyShown`, `.invalidated(reason)` or `.containerTooSmall` (the ad is discarded). Set a `VideoAdDelegate` on the ad for everything
after: `didShow`, `didRecordImpression`, `didClick`, `didEarn`, `didFail`, and exactly one `didEnd(reason:)` for every
way an ad ends, including your own `dismiss()` and `destroy()`. Resume your content in `didEnd`.

```swift
let ad = try await pause.load()
ad.delegate = self

func viewerPaused() {
    if let ad = pauseAd, ad.isReady { try? ad.show(in: playerView) } else { loadPauseAd() }   // show if ready, else load
}

func viewerResumed() {
    pauseAd?.dismiss()                                                        // didEnd(.dismissed) follows
}

extension PlayerController: VideoAdDelegate {
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        contentPlayer.play()
    }
}
```

An interstitial is presented by the SDK itself, full screen, with `show(from:)`; only the SDK dismisses it (the video
completed, a skip, a close, an error, an interruption, or your `destroy()`), and every way ends in one `didEnd`. Pause
your content before `show(from:)` and resume it in `didEnd`. `show(from:)` also throws `.cannotPresent` when the view
controller is not on screen or already presenting; the ad stays ready, try again later.

```swift
let interstitial = try await midroll.load()
interstitial.delegate = self
contentPlayer.pause()
do {
    try interstitial.show(from: self)
} catch {
    contentPlayer.play()                 // never started: undo here, no delegate call follows
}
```


### 6. Release them

When the viewer leaves the video. Nothing destroys a `VideoAds` for you, so destroy the previous episode's when
you move on.

```swift
ads.destroy()
```

## License

Apache 2.0, see [LICENSE](LICENSE).
