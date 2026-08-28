# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kontext Video SDK — an iOS SDK for integrating Kontext video ads into short-drama and other video-first apps. Distributed via Swift Package Manager and CocoaPods (`KontextVideoSDK`). Minimum deployment target: iOS 14.

**Status: pause ads only.** The SDK currently implements just the pause ad (rendered natively into a view the app provides); overlay ads and the full-screen swipe banner were removed in the simplification and will be reimplemented later — the pre-simplification code is on the `snapshot/v0-prototype` branch. The SDK speaks a JSON `POST /preload` contract that the real ad server does not implement yet — development runs against the Vite mock in [sdk-video-mock-server](https://github.com/kontextso/sdk-video-mock-server) (`pnpm dev` → `http://localhost:5175`; the example app points there). The contract is documented in that repo's README. Design doc: [SDK for short drama apps](https://app.notion.com/p/megabrainco/SDK-for-short-drama-apps-3aebafc897e280428d77deb9d82e63d2) (Notion).

Design partners:
- **HatchShorts (TCL)** — we have access to their videos: they upload them via the Kontext API with their own `external_id`, then the SDK sends only `external_id` per video.
- **StoReel** — we have no access to their videos: the SDK sends `external_id` plus `title`/`description` per video, and those are the only content context the server gets.

The sibling chat-apps SDK is [sdk-swift](https://github.com/kontextso/sdk-swift); conventions here mirror it.

## Common Commands

```bash
# Build on a real iOS Simulator (UIKit isn't on host macOS, so `swift build`
# won't work). There is no test target — iterate against the mock server.
xcodebuild build \
  -scheme KontextVideoSDK \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro' \
  -skipPackagePluginValidation

# Regenerate the example app project after changing Example/project.yml
cd Example && xcodegen generate
```

The project uses `.enableExperimentalFeature("StrictConcurrency")` in `Package.swift`, so Swift's strict concurrency checking acts as the linter. Fix all concurrency warnings as part of any PR.

## Architecture

### Public API

**`KontextVideo`** (`Sources/KontextVideoSDK/KontextVideo.swift`) — static entry point. `KontextVideo.createSession(VideoSessionOptions(...))` returns a `VideoSession`.

**`VideoSession`** — one instance per app user. Lifecycle:
1. Constructed with immutable `VideoSessionOptions` (publisher token, user id/email, enabled formats, event callback).
2. `startVideo(externalId:title:description:)` — called every time a new video starts loading. Fires `POST /preload` (publisherToken, userId, userEmail, sessionId, externalId, title, description, enabledFormats, sdk) and returns a `VideoAds` handle whose `ads: [VideoAd]` fills in when the response lands.

**`VideoAds`** — the ads prepared for one video (not the video itself), as **one placement object per format**: `pauseOverlay: PauseOverlayAd` and `pauseFullscreen: PauseFullscreenAd`, each with `isReady` / `show(in:…)` / `hide()` / `pending`. This mirrors the mobile ad SDK convention (MAX `MAInterstitialAd.isReady` + `show()`, LevelPlay `isAdReady()` + `showAd()`, AdMob `canPresent` + `present`) rather than a generic `isAdAvailable(format)`. **The SDK never observes the player** (decision 2026-08-27: pause/resume detection stays with the publisher, who already controls playback and whose player may not be `AVPlayer`). **Each ad is shown once** — `show` consumes it from `pending`; how many a video gets is the server's call. The two formats are what the server derives from the DSP's IAB `pos` (7 → `pauseFullscreen`, 8 → `pauseOverlay`). Overlay = banner at `position` (default `.top`, so the episode title at the bottom stays visible). Fullscreen = image over the whole container with a Resume button styled by `PauseFullscreenAd.Style` (it covers the app's controls, so the button is the way out): tapping it hides the ad, emits `.closed`, then calls the app's `onResume`.

**IDs** — `sessionId` is assigned by the server on the first preload response and echoed on every later request; the publisher never touches it. The persistent install ID is *not* implemented here: it comes from KontextKit's `InstallIdProvider` once that dependency is added.

### Ad formats (`Model/VideoAdFormat.swift`)

| Format | Timing contract | Frequency |
|---|---|---|
| `pauseOverlay` | Requested at video start so it can show instantly; the app shows it on pause and hides it on resume — the SDK never knows if/when a pause happens | server-decided (1 per video today) |
| `pauseFullscreen` | Same timing; Resume button is the exit | server-decided (1 per video today) |

### Internal organization

- `Sources/KontextVideoSDK/` — public types (`KontextVideo`, `VideoSession`, `VideoAds`, `PauseOverlayAd`, `PauseFullscreenAd`, `VideoSessionOptions`) at the top.
- `Sources/KontextVideoSDK/Model/` — `VideoAdFormat`, `VideoAdEvent`, `VideoAd` + `VideoAdCreative` + `VideoAdTracking` (the `/preload` response shape). The server derives it from the DSP's VAST 4.2 `<NonLinearAds>` (IAB CTV Ad Portfolio pause ad): static image + click-through + `impression`/`click`/`creativeView`/`overlayViewDuration`/`close` tracking URLs. No headline/body/CTA text — VAST has none. The mock server's `vast.js` is the reference parser.
- `Sources/KontextVideoSDK/Networking/` — `AdsService` (`POST /preload`, request/response types).
- `Sources/KontextVideoSDK/UI/` — `PauseOverlayAdUIView` (image banner), `PauseFullscreenAdUIView` (image + styled Resume button), `AdImageLoader`. The earlier gradient bottom-sheet design is on `snapshot/v0-prototype`.
- `Example/` — SwiftUI short-drama demo app (XcodeGen; see `Example/project.yml`). Home grid of stories → fullscreen vertical episode player. It links the SDK and is the integration playground.

### Privacy & attribution

Like `sdk-swift`, this SDK must not vendor IDFA / ATT / StoreKit / OMID code directly — those primitives live in [KontextKit](https://github.com/kontextso/kontextkit-ios). The dependency is not added yet; add it when the first attribution/measurement feature lands, pinned exact while KontextKit is pre-1.0 (match sdk-swift's pin).

## Conventions

- **Swift 5.9**, iOS 14.0+. `StrictConcurrency` is on — anything crossing actor boundaries must be `Sendable`.
- **`@MainActor`-isolated** anything that touches UIKit. `VideoSession`, `VideoAds` are MainActor classes. The SDK does not import AVFoundation — it renders into a `UIView` the app hands it.
- **No comments** unless the *why* is non-obvious (hidden constraint, subtle invariant, workaround). Don't reference PRs or tickets in code.
- Events are delivered on the main thread via the `onEvent` closure in `VideoSessionOptions`.

## Release Process

See `RELEASING.md`. In short: branch `release/X.Y.Z`, update `CHANGELOG.md` + `KontextVideoSDK.podspec` (`s.version`) + `SDKInfo.sdkVersion`, PR to `main`, annotated tag `X.Y.Z` (no `v` prefix), `pod trunk push`.

## Related repos

- [sdk-swift](https://github.com/kontextso/sdk-swift) — chat-apps SDK this repo mirrors conventions from
- [kontextkit-ios](https://github.com/kontextso/kontextkit-ios) — shared iOS primitives (IDFA/ATT/StoreKit/OMID), to be added as a dependency when needed
- [ads monorepo](https://github.com/kontextso/ads) — the ad server this SDK talks to
