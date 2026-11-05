# ``KontextVideoSDK``

Overlay, pause and linear video ads for short-drama and other video-first iOS apps.

## Overview

The SDK asks the Kontext ad server for ads for the episode the viewer watches, renders the creative before
the moment it is needed, and shows it in your player or full screen. It fires every beacon itself and tells
you what happens on screen through a delegate.

Three types carry an integration:

- ``KontextVideo``: the shared instance. Initialize it once at launch; it also holds what you know about the
  viewer (``KontextVideo/user``) and their consent (``KontextVideo/regulatory``).
- ``VideoAds``: the ads of one episode. Create one per episode, track its player, and
  ``VideoAds/destroy()`` it when the viewer leaves.
- ``VideoAd``: one ad. Read its ``VideoAd/price``, ``VideoAd/load()`` it or ``VideoAd/reject(_:)`` it, then
  show it.

Requirements: iOS 14 or later, Swift 5.9, Swift Package Manager. The integration guide is at
[docs.kontext.so/video/sdk/swift](https://docs.kontext.so/video/sdk/swift).

## Getting started

Initialize the SDK at app launch with your publisher token:

```swift
KontextVideo.shared.initialize(with: .init(publisherToken: "yourapp-dev"))
```

Create a ``VideoAds`` for each episode and track the player it plays in:

```swift
let ads = VideoAds(content: .init(id: "series-1-ep-6", language: "en"))
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

``AdFormat`` names the three formats. Every request asks for all of them; ``VideoAds/format(_:)`` returns
one.

- ``AdFormat/overlay``: a strip across the player while the content plays. Show it with
  ``VideoAd/show(in:insets:)``; it ends after its ``VideoAd/duration`` of video, or when the content stops.
- ``AdFormat/pause``: a card, or the whole player, while the content is paused. Show it with
  ``VideoAd/show(in:insets:)``; it ends when the viewer closes it or resumes, or with ``VideoAd/dismiss()``.
- ``AdFormat/linear``: a full-screen video at a moment you pick. Show it with ``VideoAd/show(from:)``; only
  the SDK dismisses it.

Show an episode's ads only in that episode: a player belongs to one ``VideoAds`` at a time.

## Lifecycle

`format` returns an ad with nothing rendered; `load` renders it; `show` either throws, and nothing happened,
or the ad begins to show. Then the impression, at most once, and any clicks; then exactly one
``VideoAdDelegate/videoAd(_:didEnd:)``, whoever ended it. Nothing is delivered through the delegate before
`show`: an ad that can no longer be shown says so when `load` or `show` throws a ``VideoAdError``.

At most one ad is on screen in the whole app. The SDK never requests an ad by itself: every request comes
from your `format(_:)` call.

## Privacy

The SDK reads consent from your consent management platform's IAB keys and lets you fill in what it did not
write through ``KontextVideo/Regulatory``; COPPA can only come from you. It sends the advertising identifier
only when the viewer allowed tracking, and shows the App Tracking Transparency dialog only when you ask it to
(``KontextVideo/Configuration/requestTrackingAuthorization``). A COPPA request carries no advertising id and
no user id or email. The package ships a privacy manifest.

## Topics

### Essentials

- ``KontextVideo``
- ``VideoAds``
- ``VideoAd``
- ``AdFormat``

### On screen

- ``VideoAdDelegate``
- ``ContentPlayer``

### Errors

- ``VideoAdError``
