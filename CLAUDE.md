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
1. Constructed with immutable `VideoSessionOptions` (publisher token, user id/email, ad server URL, event callback). Formats are **not** a session setting — they are chosen per request in `load(formats:)`.
2. `setVideo(id:title:description:duration:language:episodeNumber:series:)` — called every time a new video becomes current. `id` is the publisher's unique video id, their scheme (decided 2026-08-31, renamed from `externalId`; public echoes are `videoId`). Episode-ish fields sit flat on the call; series-level context (synopsis, keywords, `contentRating`, languages, episode count — where short-drama publishers like StoReel actually have data, per their 2026-08 availability sheet: episodes carry only id/duration/language) goes in `series: VideoSeries?`. Public API uses `duration: TimeInterval` in **seconds** — the `Ms` suffix is an internal-constant convention in our SDKs, never public API; the wire stays `duration_ms` like `start_ms`/`skip_after_ms`. **Does not request anything**; returns the `VideoAds` handle (also `session.currentVideo`). `ads.load(formats:)` fires `POST /preload` (publisher_token, user_id, user_email, session_id, id, title, description, duration_ms, language, episode_number, series{…}, formats, sdk) for exactly the listed formats — no default, an empty list is a programmer error (`assertionFailure`, no request); `ads.pause.load()` (etc.) requests just that format. Loads **append** to `pending`, are ignored while one is in flight (`isLoading`), and a response for a video that is no longer current is dropped. Decision 2026-08-30: set-video and load are separate so the app can re-request after an ad was consumed; fill frequency is the server's call.
3. `await ads.destroy()` — releases the video's ads (name per MAX / sdk-swift `destroy()`). Async on purpose: an ad view on screen must stay in the hierarchy for `Constants.teardownDelay` (1 s) after Open Measurement's `finish()` so the OM script can send its final beacons — the OM call itself is not wired yet but the delay and the hook are. Cancels an in-flight load, makes `load`/`show` no-ops (`isDestroyed`), drops `pending`. `setVideo` destroys the previous handle in the background, so most apps never call it directly.

**`VideoAds`** — the ads prepared for one video (not the video itself), as **one placement object per format**: `pause: PauseAd`, `swipe: SwipeAd`, `overlay: OverlayAd` (all subclasses of `AdPlacement`, which owns the queue, reveal delay, tracking, viewability and teardown; subclasses only build and lay out the view), each with `isReady` / `show(in:…)` / `hide()` / `load()` / `pending`. This mirrors the mobile ad SDK convention (MAX `MAInterstitialAd.isReady` + `show()`, LevelPlay `isAdReady()` + `showAd()`, AdMob `canPresent` + `present`) rather than a generic `isAdAvailable(format)`. **The SDK never observes the player** (decision 2026-08-27: pause/resume detection stays with the publisher, who already controls playback and whose player may not be `AVPlayer`). **Each ad is shown once** — `show` consumes it from `pending`; how many a video gets is the server's call. The pause ad is a banner at `position` (default `.top`, so the episode title at the bottom stays visible), look via `PauseAd.Style` (= `BannerStyle`: margins from the safe-area edges, `maxWidth` for wide players, corner radius, placeholder colour). **The fullscreen pause variant was removed 2026-08-31** (colleagues' decision — pause is banner-only; the code is in git history / `snapshot/v0-prototype` era commits).

**IDs** — `sessionId` is assigned by the server on the first preload response and echoed on every later request; the publisher never touches it. The persistent install ID is *not* implemented here: it comes from KontextKit's `InstallIdProvider` once that dependency is added.

### Ad formats (`Model/VideoAdFormat.swift`)

| Format | Timing contract | Frequency |
|---|---|---|
| `pause` (`INSTREAM_IMAGE_PAUSE`) | Requested at video start so it can show instantly; the app shows it on pause and hides it on resume — the SDK never knows if/when a pause happens | server-decided (1 per video today) |
| `overlay` (`INSTREAM_IMAGE_OVERLAY`, the ad server's existing format) | N ads per video, each with `trigger { kind: range, from_ms, to_ms }` from the server's scene analysis (= `/instream/vmap`'s `AdBreak@timeOffset` + `kontext:Overlay@endMs`). **Push, don't own** (decided 2026-08-30 — no `attach(player:)`, apps have many players/providers): the app sets `ads.overlay.playhead` from its own time observer; the SDK calls `onWindowOpen(ad)` / `onWindowClose(ad)`; the app calls `show(in:)` / `hide()` — or ignores windows and shows any time (`show(in:)` prefers the open-window ad, else the next pending; `show(_:in:)` for a specific one). Windows are hints; an ignored ad stays in `pending`. **Manual mode (2026-08-31):** when the publisher shares no content the server can derive no windows and sends `trigger { kind: "manual" }` — the app decides the moment, pause-ad style (`isReady` → `show(in:)`). Modes mix; `show(in:)` prefers open-window → manual → next pending, so a manual show never steals a scheduled ad. Shares `BannerAdUIView` / `BannerStyle` / `BannerPosition` with the pause overlay; position defaults to the server's `placement.position`. | server-decided (several) |
| `swipe` (`INSTREAM_VIDEO_SWIPE`) | Loaded with the video; shown by the app as a **page in its feed** when the user swipes to the next episode (Google's `SwipeableInterstitialAd` model: app hosts the view, holds the swipe for `screenHoldDuration` = our server-driven `playback.skip_after_ms`). SDK plays the VAST `<Linear>` MP4 with its own `AVPlayer`, sound on by default (`playback.muted`), Skip chip counts down. `onSkippable` → app unblocks the swipe; `onFinished` → app moves on (fires on completion **and** on the ad's own Skip button — bug found 2026-08-30: Skip left the app with a black host); app calls `hide()` when the user swiped it away (fires `video.skip`, emits `.closed`); completion fires `video.complete`, emits `.completed`. Quartiles go to the ad server's existing `/impression/{bid}/vast?event=`. Decided 2026-08-30: transition is the app's (option a), skippability server-driven, sound on. **It is an interstitial, not a feed item** (decided 2026-08-30 after trying the Instagram feed-page model: Google's swipeable interstitial is one-shot, and a persistent ad page made SwiftUI's paging jump when a second page was inserted). Shown once on a *forward* swipe (the app checks episode order), dismissed by swipe/completion, and never shown again — a revealed ad is consumed. | max 1 per video |

### Internal organization

- `Sources/KontextVideoSDK/` — public entry points (`KontextVideo`, `VideoSession`, `VideoAds`, `VideoSessionOptions`) at the top.
- `Sources/KontextVideoSDK/AdFormats/` — one folder per format, each holding the placement object and its view (mirrors sdk-swift's `InlineAd/`, `InterstitialAd/`): `Pause/PauseAd`, `Swipe/{SwipeAd, SwipeAdUIView}`, `Overlay/OverlayAd`; shared at the folder root: `AdPlacement` base class (queue, optional delay, tracking, viewability, teardown), `BannerAdUIView` + `BannerStyle`/`BannerPosition` (image banners for pause and overlay), `AdImageLoader`. A new format = a new folder here + a case in `VideoAdFormat` + a property on `VideoAds`.
- `Sources/KontextVideoSDK/Model/` — `VideoAdFormat`, `VideoAdEvent`, `VideoAd` + `VideoAdCreative` + `VideoAdTracking` (the `/preload` response shape). The server derives it from the DSP's VAST 4.2 `<NonLinearAds>` (IAB CTV Ad Portfolio pause ad): static image + click-through + `impression`/`click`/`creativeView`/`overlayViewDuration`/`close` tracking URLs. No headline/body/CTA text — VAST has none. The mock server's `vast.js` is the reference parser.
- `Sources/KontextVideoSDK/Networking/` — `AdsService` (`POST /preload`, request/response types).
- `Sources/KontextVideoSDK/Tracking/` — `AdTracker` (pings), `ViewabilityMeter` (MRC). The earlier gradient bottom-sheet pause design is on `snapshot/v0-prototype`.
- `Example/` — SwiftUI short-drama demo app (XcodeGen; see `Example/project.yml`). Home grid of stories → fullscreen vertical episode player. It links the SDK and is the integration playground.

### Privacy & attribution

Like `sdk-swift`, this SDK must not vendor IDFA / ATT / StoreKit / OMID / in-app-browser code directly — those primitives live in [KontextKit](https://github.com/kontextso/kontextkit-ios), added as a dependency pinned `exact: "0.1.0"` (match sdk-swift's pin; `from:` once KontextKit is 1.0). First use: `InAppBrowserManager.shared.present(url:)` for the click-through (2026-08-30). Next candidates: `InstallIdProvider` for the install id, `OMManager` for the native OM session.

### Wire contract & tracking (decided 2026-08-30 after mapping the ad server)

- Request `POST {adServerURL}/instream/preload`, **snake_case** (the ad server's `/instream/live` vocabulary): `publisher_token, user_id, user_email, session_id, external_id, title, description, formats[], context{player_width,player_height}, sdk{name,platform,version}`. Response `{ session_id, ads[], no_fill_reason, next_request_at }`.
- Format strings are the ad server's `AdFormat` enum names: `INSTREAM_IMAGE_PAUSE` (raw value of `VideoAdFormat.pause`; `IMAGE` because pause ads are static — a video variant would be `INSTREAM_VIDEO_PAUSE`). Each ad = `format, bid_id, creative_id, trigger{kind:'pause', delay_ms}, placement{position}, creative{image{url,w,h}, headline?, body?, cta{text,mode,url}, advertiser{name,logo_url}?}, tracking{…}` — `creative`/`tracking` are the server's existing `InstreamOverlayAdJson` (`apps/ad-server/app/api/frame/[id]/instream-json.ts`) and `TrackingUrls` (`app/instream/modules/tracking.ts`) verbatim. The server side does not exist yet; the mock server implements this contract.
- **Tracking** (`Tracking/AdTracker.swift`, `Tracking/ViewabilityMeter.swift`, orchestrated in `PausePlacement`): `impression` + `creative_view` when the image is painted (not on `show`); MRC display viewability — ≥50 % for 1 continuous second, timed not waited, app active, only after the impression — then exactly one of `viewable` / `not_viewable` / `view_undetermined`; tap opens `click_through` (server records the click via `/redirect`); `overlay_view_duration` on every hide plus `close` on user dismiss. At most once per URL per bid (server dedupes `/view` and `/click`, not `/event`). Pings are **POST** (the routes accept GET for VAST players and POST for SDKs; the body repeats the query's `e=` as `{event}` so either server-side reading works). Macros: `[CACHEBUSTING]` random, `[TIMESTAMP]` ISO-8601, others empty. This mirrors `video-ad-formats/apps/videonexus/src/ads/tracking/`.
- `VideoAdCreative.image` / `.video` are optional — image formats carry one, video formats the other. `VideoAdTracking.video` (start/quartiles/complete/skip/mute/unmute) is present for video formats only.
- **Show immediately on pause — requirement (2026-08-30).** `trigger.delay_ms` stays on the wire as an optional per-ad grace period the server may set (absent/0 = immediate; the mock sends 0). When it is set, `hide()` during the wait cancels the reveal and keeps the ad queued; the ad is consumed only when it actually appears, so a tap-tap never burns a bid. The 2 s default copied from video-ad-formats / Peacock was wrong for us and is gone. From `PauseOverlayDescriptor.delayMs` in video-ad-formats.
- A failed request emits `.error` only; `.noFill` (with the server's `reason`) means the server answered and had nothing.

## Roadmap decisions

- **`VideoSessionOptions` expansion (planned, decided 2026-08-31; not implemented).** From comparing sdk-swift's `SessionOptions` and the public `/v1/ads` params (samsung.kontext.ai):
  - *Must (before any partner integration):* `regulatory: Regulatory?` (gdpr, gdprConsent, coppa, gpp, gppSid, usPrivacy — the `/instream/live` shape; KontextKit `TCFDataProvider` as auto-fallback); advertising identity — `advertisingId`/`vendorId` overrides + `requestTrackingAuthorization: Bool = true` running KontextKit's ATT startup flow, sending `ifa`/`ifa_type` and deriving `limit_ad_tracking`; **make `userId` optional** (the public API's rule is "user_id or ifa" — some publishers won't share a user id); `session.updateOptions(...)` for the mutable subset (regulatory, userEmail, advertisingId, vendorId, variantId — consent arrives late from a CMP, email after login, IFA after ATT).
  - *Should:* `variantId: String?` (A/B); `ctaMode: .button | .qr` (session-level device trait, default `.button` for touch; QR the moment this contract serves TV).
  - *Not:* `conversationId`/`character`/`enabledPlacementCodes` (chat concepts — the video `id` and formats-per-`load` cover them); `max_slots`/`content_id` stay request-level; `onDebugEvent` only once an `/init`-style server flag exists to gate reporting.


- **Custom ad views (binding API) → v2.0.** Decided 2026-08-30. v1 ships the SDK-owned views + `Style` only. v2 adds a MAX/Meta-style escape hatch: `show(in:custom:onResume:)` with a `PauseAdBinding { view, imageView, clickableViews, resumeControl, adBadgeView? }` — publisher owns layout, SDK still loads the image, routes clicks + tracking, ensures the AD badge, registers OM, applies the teardown delay. Fullscreen first; overlay only on demand. Never document "render `VideoAd` yourself" — it loses measurement.

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
