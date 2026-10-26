# Integration guide: Kontext Video SDK for iOS

How to put Kontext video ads (overlay, pause, linear) into an iOS app. This guide will move to
[docs.kontext.so](https://docs.kontext.so) when the video SDK's page is published; until then it lives here.
Contributors: [DEVELOPMENT.md](../DEVELOPMENT.md). Releases: [RELEASING.md](../RELEASING.md), [CHANGELOG.md](../CHANGELOG.md).

The SDK builds on [KontextKit](https://github.com/kontextso/kontextkit-ios) for the device, privacy and StoreKit
facts it sends.

## Requirements

iOS 14 or later, Swift 5.9 (Xcode 15.0+). The SDK is UIKit-based; SwiftUI apps host their player in a
`UIViewRepresentable`, as the example does.

## Installation

Swift Package Manager, in Xcode (File → Add Package Dependencies) or in `Package.swift`:

```swift
.package(url: "https://github.com/kontextso/sdk-swift-video.git", from: "0.1.0")
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
them; bids already received keep the values they were requested with. `nil` clears a value.

```swift
KontextVideo.shared.user = .init(id: "u_84213907", email: "ryan@example.com")
KontextVideo.shared.regulatory = .init(coppa: false)        // the rest is read from your CMP's storage
                                                            // (IABTCF_*, IABGPP_*, IABUSPrivacy_String); the CMP's values win,
                                                            // yours fill in what it did not write
KontextVideo.shared.variantId = "experiment-b"              // A/B testing, agreed with Kontext
```

### 2. The playhead

There is no player object to conform or wrap. The SDK assumes a full-screen player: every request carries the screen
in its current orientation, the server picks ad sizes and positions for it, and `show(in:)` fits the ad into the real
view at that moment. The one fact it needs from your player is the content playhead, which it *reads* when it needs
one (at a request, in beacon macros) rather than having you push it. For an `AVPlayer`, `trackPlayhead(of:)` is the
whole integration; for any other player set a closure. This is Google IMA's model (`IMAContentPlayhead`,
`IMAAVPlayerContentPlayhead`), without the protocol.

```swift
ads.trackPlayhead(of: avPlayer)                   // AVPlayer: the SDK reads currentTime() itself, holds the player weakly
ads.playheadProvider = { myPlayer.currentTime }   // any other player: seconds
```

Attach the playhead any time: a request made before the player exists carries content time 0, which is what a
prefetch should say. With one `AVPlayer` reused across episodes (`replaceCurrentItem`), call `trackPlayhead(of:)` when
the episode starts playing in it, not when you create the `VideoAds`, or the next episode's prefetch would carry the
previous episode's time.

### 3. Create the ads for a video

One `VideoAds` per video (episode). Creating it sends nothing; every request comes from `format(_:)`. Create it as
early as you like, for example for the next episode while the current one plays; any number can be alive at once.
`KontextVideo.Content` describes the video ("content" is the ad-industry word for it): `id` is your own id, in any
scheme; everything else is optional context that helps targeting. Times are seconds. Leave `mediaRating` unset when
you do not know it; the SDK never guesses.

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

### 4. Get a bid, load it early, or reject it

`ads.format(.pause)` gives you the bid for one format as a `VideoAd.Bid`: its facts (`price`, `size`, `duration`, ...),
nothing rendered yet. Every call asks the server for **all** formats and lists the unshown bids the SDK holds; the
server returns those unchanged until they expire, so you get the same bid (and its loaded ad) back, and the bids for
the other formats wait for their own `format(_:)` call. Which formats a publisher has, and their demand, floors and
caps, are configured in the Kontext dashboard; you name nothing. Calls made while a request runs share it: call
`format(_:)` for several formats at once with `async let`, one request answers all of them.

`bid.load()` renders the creative and returns a `VideoAd` ready to show; a second `load()` returns the same ad. Load
early, so that at the moment (the viewer pauses) only `show` runs. A `VideoAds` holds at most one unshown bid per
format; drop your reference and the SDK still keeps it, loaded, for the next `format(_:)` call.

When you do not use a bid (another network won your own auction, the moment passed) call `reject()`, on the bid or on
the loaded ad: the SDK tells the server, which tells the buyer; the WebView is released and the next `format(_:)`
gets a new bid. It works until `show` and throws afterwards (`.alreadyShown`).

```swift
// Early: when the episode opens, or in didEnd of the previous ad
let pause = try await ads.format(.pause)
if pause.price.value >= otherNetworkPrice {        // your own auction, if you run one
    pauseAd = try await pause.load()                // ready to show
} else {
    try pause.reject(.outbid(winningPrice: otherNetworkPrice))
}

// Several formats at once: one request
async let pauseBid = ads.format(.pause)
async let linearBid = ads.format(.linear)
let (p, l) = try await (pauseBid, linearBid)

// No fill and failures are errors
do {
    let bid = try await ads.format(.pause)
} catch VideoAdError.noFill(let reason) {
    // nothing to show; reason: noAdMatch, frequencyCap, formatNotEnabled (no configuration for this format), …
    // the next call asks again
} catch {
    // .request(error) (only when no valid bid is held; otherwise that one is returned), .notInitialized,
    // .initializationFailed, .disabled(reason:), .destroyed, CancellationError
}
```

`load()` throws `.creativeFailed(code:)` (the creative failed, or did not report ready within 10 s of active time),
`.invalidated(.expired)` (the bid's lifetime ran out, before or during the load), `.invalidated(.rejected)`,
`.destroyed`, `.disabled(reason:)`. Expiry is found out at the next call, never delivered: a bid or a loaded ad that can
no longer be shown says so when `load()` or `show` throws. Cancelling the task that awaits `format(_:)` or `load()`
stops only that call (`CancellationError`); the request or the load continues and its result is kept.

### 5. Show it, listen, dismiss

Overlay and pause ads are shown with `show(in:)`, inside the view your content plays in: the one holding the
`AVPlayerLayer`, or `contentOverlayView` of an `AVPlayerViewController`, or a `UIViewRepresentable`-hosted view in
SwiftUI. The SDK places its own view in it at the ad's position and size (a full-screen pause ad fills it);
`dismiss()` ends a pause ad when your content resumes. An overlay ends by itself when its `duration` of time on screen elapses
(`didEnd(.completed)`; the clock freezes while the app is in the background); `dismiss()` is for ending it earlier (the content ended, a seek). `show` throws when
presentation cannot begin (nothing fired):
`.alreadyShown`, `.anotherAdShowing` (one ad on screen in the whole app: show it after the other ended),
`.invalidated(reason)`, `.disabled(reason:)`, `.wrongPresentation` (`show(in:)` on a linear ad) or
`.containerTooSmall` (the ad stays ready: show it in a bigger view, or reject it). `show` succeeds once the ad is on
screen; there is no "did show" callback. If your view leaves the window while the ad is on it (you navigated away
without `dismiss()`), the ad ends with `didEnd(.interrupted)` within about half a second, so it never blocks the next one. Set a `VideoAdDelegate` on the ad for everything after:
`didRecordImpression` (at most once, maybe never), `didClick` (every tap), `didFail`, and exactly one
`didEnd(reason:)` for every way an ad ends, including your own `dismiss()` and `destroy()` (delivered synchronously,
from inside that call). Resume your content in `didEnd`, and only there.

```swift
pauseAd.delegate = self

func viewerPaused() {
    if let ad = pauseAd, ad.isReady { try? ad.show(in: playerView) } else { preparePauseAd() }   // instant; else prepare the next
}

func viewerResumed() {
    try? pauseAd?.dismiss()                                                   // didEnd(.dismissed) follows
}

extension PlayerController: VideoAdDelegate {
    func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) {
        switch ad.format {
        case .linear: contentPlayer.play()                          // the ad paused the content: every ending resumes it
        case .pause: if reason == .resumed { contentPlayer.play() } // the viewer paused: only Resume says play
        case .overlay: break                                        // the content never stopped
        }
    }
}
```

A linear ad is presented by the SDK itself, full screen: `show()` presents from the key window's top view
controller (as AdMob's `present(from: nil)` and MAX's `showAd()` do), `show(from:)` from a controller you name when
that guess would be wrong (a player presented as a sheet, a second window). Only the SDK dismisses it (the video
completed, a skip, a close, an error, an interruption, or your `destroy()`; `dismiss()` throws
`.wrongPresentation`), and every way ends in one `didEnd`. Pause
your content before `show` and resume it in `didEnd`. `show` also throws `.presenterUnavailable` when no view
controller can present right now (yours is off screen or already presenting; with `show()`, no key window or a top
controller mid-transition); the ad stays ready, try again later or pass the right controller.

```swift
let linear = try await ads.format(.linear).load()   // early
linear.delegate = self
contentPlayer.pause()
do {
    try linear.show()                      // or show(from: self)
} catch {
    contentPlayer.play()                 // never started: undo here, no delegate call follows
}
```


### 6. Release them

When the viewer leaves the video. Every bid it still holds, loaded or not, is released and the server told it was not
used; an ad of it still on screen ends with `didEnd(.destroyed)`, so nothing of episode 5 sits over episode 6.
Releasing the object does the same, best effort; call `destroy()` explicitly when you move on.

```swift
ads.destroy()
```

## License

Apache 2.0, see [LICENSE](LICENSE).
