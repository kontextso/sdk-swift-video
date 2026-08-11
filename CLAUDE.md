# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kontext Video SDK — an iOS SDK for integrating Kontext video ads into short-drama and other video-first apps. Distributed via Swift Package Manager and CocoaPods (`KontextVideoSDK`). Minimum deployment target: iOS 14.

**Status: skeleton.** The public API surface exists and compiles; the ad rendering, player observation, and the server `/preload` endpoint are not implemented yet. Design doc: [SDK for short drama apps](https://app.notion.com/p/megabrainco/SDK-for-short-drama-apps-3aebafc897e280428d77deb9d82e63d2) (Notion).

Design partners:
- **HatchShorts (TCL)** — we have access to their videos: they upload them via the Kontext API with their own `external_id`, then the SDK sends only `external_id` per video.
- **StoReel** — we have no access to their videos: the SDK sends `external_id` plus `title`/`description` per video, and those are the only content context the server gets.

The sibling chat-apps SDK is [sdk-swift](https://github.com/kontextso/sdk-swift); conventions here mirror it.

## Common Commands

```bash
# Build and test on a real iOS Simulator (UIKit isn't on host macOS, so
# `swift build` / `swift test` won't work).
xcodebuild build \
  -scheme KontextVideoSDK \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro' \
  -skipPackagePluginValidation

xcodebuild test \
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
2. `attachPlayer(playerView:player:)` — the publisher hands over their player so the SDK can render ads over it and observe playback (pause detection). Player integrations differ per publisher; with only 1–5 publishers expected, richer variants are designed with each partner.
3. `startVideo(externalId:title:description:)` — called every time a new video starts loading. Fires `/preload` for all enabled formats and returns a `VideoAds` handle.

**`VideoAds`** — the ads prepared for one video (not the video itself). Overlay and pause ads show automatically; `showSwipeBanner()` is the one call the app makes itself, on the handle so the target video is unambiguous even when the next episode is already preloading.

**IDs** — the SDK manages both automatically; the publisher never touches them:
- `installId` (`Utils/InstallID.swift`) — persistent, generated on first launch, stored in `UserDefaults`.
- `sessionId` — assigned by the server on the first preload response, echoed on every later request.

### Ad formats (`Model/VideoAdFormat.swift`)

| Format | Timing contract | Frequency |
|---|---|---|
| `overlay` | All requested at the start of the video (same model as the video API) | N per video |
| `pauseAd` | Requested with the other formats at video start so it can show instantly on pause; we never know if/when/how often a pause happens | 1 per video (v1 simplification) |
| `swipeBanner` | Must be ready **before** the swipe — the swipe is too quick to generate an ad after it; can happen at any point in the video; the ad is connected to the previous video | max 1 per video |

### Internal organization

- `Sources/KontextVideoSDK/` — public types (`KontextVideo`, `VideoSession`, `VideoAds`, `VideoSessionOptions`) at the top.
- `Sources/KontextVideoSDK/Model/` — `VideoAdFormat`, `VideoAdEvent`.
- `Sources/KontextVideoSDK/Networking/` — `PreloadService` + request/response types. The `/preload` endpoint is tentative and not implemented server-side yet; the types here are the SDK-side sketch of the contract.
- `Sources/KontextVideoSDK/Utils/` — `InstallID`.
- `Example/` — SwiftUI short-drama demo app (XcodeGen; see `Example/project.yml`). Home grid of stories → fullscreen vertical episode player. It links the SDK and is the integration playground.

### Privacy & attribution

Like `sdk-swift`, this SDK must not vendor IDFA / ATT / StoreKit / OMID code directly — those primitives live in [KontextKit](https://github.com/kontextso/kontextkit-ios). The dependency is not added yet; add it when the first attribution/measurement feature lands, pinned exact while KontextKit is pre-1.0 (match sdk-swift's pin).

## Conventions

- **Swift 5.9**, iOS 14.0+. `StrictConcurrency` is on — anything crossing actor boundaries must be `Sendable`.
- **`@MainActor`-isolated** anything that touches UIKit/AVPlayer. `VideoSession`, `VideoAds` are MainActor classes.
- **No comments** unless the *why* is non-obvious (hidden constraint, subtle invariant, workaround). Don't reference PRs or tickets in code.
- Events are delivered on the main thread via the `onEvent` closure in `VideoSessionOptions`.

## Release Process

See `RELEASING.md`. In short: branch `release/X.Y.Z`, update `CHANGELOG.md` + `KontextVideoSDK.podspec` (`s.version`) + `SDKInfo.sdkVersion`, PR to `main`, annotated tag `X.Y.Z` (no `v` prefix), `pod trunk push`.

## Related repos

- [sdk-swift](https://github.com/kontextso/sdk-swift) — chat-apps SDK this repo mirrors conventions from
- [kontextkit-ios](https://github.com/kontextso/kontextkit-ios) — shared iOS primitives (IDFA/ATT/StoreKit/OMID), to be added as a dependency when needed
- [ads monorepo](https://github.com/kontextso/ads) — the ad server this SDK talks to
