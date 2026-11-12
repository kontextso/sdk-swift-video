# ``KontextVideoSDK``

Overlay, pause, full-screen pause and linear video ads for short-drama and other video-first iOS apps.

## Overview

The SDK asks the Kontext ad server for ads for the episode the viewer watches, renders the creative before
the moment it is needed, and shows it in your player or full screen. It fires every beacon itself and tells
you what happens on screen through a delegate.

Three types carry an integration:

- ``KontextVideo``: the shared instance. Initialize it once at launch; it also holds the viewer
  (``KontextVideo/user``, required before the first ads request) and their consent (``KontextVideo/regulatory``).
- ``VideoAds``: the ads of one episode, in one section of the app. Create one per episode, track its player,
  and ``VideoAds/destroy()`` it when the viewer leaves.
- ``VideoAd``: one ad. Read its ``VideoAd/price``, ``VideoAd/load()`` it or ``VideoAd/reject(_:)`` it, then
  show it.

Requirements: iOS 14 or later, Swift 5.9, Swift Package Manager. The integration guide is at
[docs.kontext.so/video/sdk/swift](https://docs.kontext.so/video/sdk/swift).

## Getting started

Initialize the SDK at app launch with your publisher token, and set the viewer before the first ads request,
a guest id until they sign in, then the account id, at most 256 characters (without a user, ``VideoAds/format(_:)`` throws
``VideoAdError/RequestFailure/missingUser`` and sends nothing):

```swift
KontextVideo.shared.initialize(with: .init(publisherToken: "yourapp-dev"))
KontextVideo.shared.user = .init(id: viewerId)
```

Create a ``VideoAds`` for each episode and track the player it plays in. Its `section` names where in the app
the player is, as agreed with Kontext; the server's configuration picks the formats it offers there. An A/B
variant agreed with Kontext goes in `variantId`.

```swift
let ads = VideoAds(content: .init(id: "series-1-ep-6", language: "en"), section: "episode")
ads.track(player)   // an AVPlayer, or your own player conformed to ContentPlayer
```

Ask for an ad before its moment, so `show` is instant:

```swift
let ad = try await ads.format(.pause)
try await ad.load()
ad.delegate = self
```

At the moment, show it; the delegate hears the impression, clicks and exactly one `didEnd`:

```swift
player.pause()
try ad.show(in: playerView)
```

Call ``VideoAds/destroy()`` when the viewer leaves the episode.

## Formats

``AdFormat`` names the four formats. Every request asks for all of them; the answer carries the formats the
publisher configured for the ``VideoAds/section``, and ``VideoAds/format(_:)`` returns one.

- ``AdFormat/overlay``: a strip across the player while the content plays. Show it with
  ``VideoAd/show(in:insets:)``; it ends after its ``VideoAd/duration`` of video, or when the content stops.
- ``AdFormat/pause``: a card over the top or the bottom of the player while the content is paused. Show it
  with ``VideoAd/show(in:insets:)``; it ends when the viewer closes it or the content plays again, or with
  ``VideoAd/dismiss()``.
- ``AdFormat/pauseFullscreen``: the whole player while the content is paused, the same way: its Resume ends it
  as `.resumed`, its ✕ as `.closed`, the content playing again as `.interrupted`.
- ``AdFormat/linear``: a full-screen video at a moment you pick. Show it with ``VideoAd/show(from:)``; only
  the SDK dismisses it.

Show an episode's ads only in that episode: a player belongs to one ``VideoAds`` at a time.

## Lifecycle

`format` returns an ad with nothing rendered; `load` renders it; `show` either throws, and nothing happened,
or the ad begins to show. Then the impression, at most once, and any clicks; then exactly one
``VideoAdDelegate/videoAd(_:didEnd:)``, whoever ended it. Nothing is delivered through the delegate before
`show`: an ad that can no longer be shown says so when `load` or `show` throws a ``VideoAdError``.

A click opens a web link in an in-app browser over your app, unless an installed app claims it; an app's own
link and an App Store link open that app. The ad waits under the browser, its time paused, and goes on when
the viewer taps Done.

At most one ad is on screen in the whole app. The SDK never requests an ad by itself: every request comes
from your `format(_:)` call.

## Privacy

The SDK reads consent from your consent management platform's IAB keys and lets you fill in what it did not
write through ``KontextVideo/Regulatory``; COPPA can only come from you. It sends the advertising identifier
only when the viewer allowed tracking, and shows the App Tracking Transparency dialog only when you ask it to
(``KontextVideo/Configuration/requestTrackingAuthorization``). A COPPA request carries no advertising id, no
IDFV and no email or email hash; the user id is still sent, and the server keeps it from buyers. The package ships a privacy manifest.

## Topics

### Essentials

- ``KontextVideo``
- ``VideoAds``
- ``VideoAd``
- ``AdFormat``

### On screen

- ``VideoAdDelegate``
- ``ContentPlayer``

### SwiftUI

- ``VideoAdHost``

### Errors

- ``VideoAdError``
- ``VideoAdError/NoFillReason``
- ``VideoAdError/RequestFailure``
