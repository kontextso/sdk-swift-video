# AGENTS.md

Shared guidance for coding agents (Codex, Claude Code, others) in this repository. One set of rules: `CLAUDE.md`
only points here. Details live in [DEVELOPMENT.md](DEVELOPMENT.md), the release in [RELEASING.md](RELEASING.md).

## Project

Kontext Swift Video SDK: overlay, pause and linear ads in short-drama and other video-first apps. Swift 5.9,
iOS 14+, Swift Package Manager only (CocoaPods trunk is read-only from December 2026). The contract is the Notion
document *Video Ads API & SDK v2*; the behavior is the Notion page *SDK Lifecycle*, and the code implements it
line by line. Timed mode (windows, `nextRequestAt`) is specified on the Notion pages but deliberately not in the
SDK: an ad with a `window` trigger is dropped and reported (only `manual` is taken), and `nextRequestAt` is not
read. Integration guide for publishers:
https://docs.kontext.so/video/sdk/swift. Kotlin twin: [sdk-kotlin-video](https://github.com/kontextso/sdk-kotlin-video).

## Contract, and which source wins

1. The Notion pages (internal; the repo is public, so referenced by title): *Video Ads API & SDK v2* for the wire,
   *SDK Lifecycle* for the public behavior, *Kontext Frame Protocol (v2)* for the page bridge, *Tracking Events
   (beacons)* for the beacons.
2. This code implements them; the mock server (`sdk-video-mock-server`, internal) follows them too.
3. When the code, the mock and a page disagree, the page wins: do not "fix" the page to match the code. If the
   page looks wrong, stop and say so; a public API change goes to *SDK Lifecycle* first.

## Commands

The SDK imports UIKit and WebKit: `swift build` / `swift test` do not work on the host; build and test on a
simulator. Pick any available iPhone by name (`xcrun simctl list devices available`), never a device UUID.

```bash
# Build
xcodebuild build -scheme KontextVideoSDK-Package -destination 'generic/platform=iOS Simulator'

# Tests: all (about 2 min locally, 4 on CI), or one suite (suites under SerialSuites need that prefix)
xcodebuild test -scheme KontextVideoSDK-Package -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro'
xcodebuild test -scheme KontextVideoSDK-Package -destination '…' -only-testing:KontextVideoSDKTests/SerialSuites/VideoAdTests
xcodebuild test -scheme KontextVideoSDK-Package -destination '…' -only-testing:KontextVideoSDKTests/DecodingTests

# Lint, the compiler-warnings rule, and the analyzer, as CI runs them
swiftlint lint --strict
xcodebuild clean build -scheme KontextVideoSDK-Package -destination 'generic/platform=iOS Simulator' > xcodebuild.log 2>&1
grep -E "Sources/KontextVideo(SDK|TTSDK)/.*: warning:" xcodebuild.log   # must print nothing
swiftlint analyze --strict --compiler-log-path xcodebuild.log
```

Check the exit status of `xcodebuild` itself, not of a `grep` piped after it: a red test run must not pass for
green. CI builds with Xcode 16.4 (iOS 18 SDK), which can warn where a newer local Xcode does not. The example (`Example/`, XcodeGen) talks to
the ad server by default, or the mock `sdk-video-mock-server` on `localhost:5175` through `adServerURL`: five videos (two overlay, one
linear, two pause); the overlay and linear ads show 3 s in, a pause ad when the viewer pauses. See
[DEVELOPMENT.md](DEVELOPMENT.md).

## Architecture

- `KontextVideo.shared`: initialize (`/config`), `user`, `regulatory`, `variantID`, the one ad on screen; the shell
  that moves `SdkState`.
- `VideoAds`: one per video. `format(_:)` asks the server for all formats with the `VideoAds`'s `sessionId` and the
  ids of the unshown bids it holds (`held`); the server owns the bid state and re-serves held bids until they
  expire; the SDK follows the response. One request at a time, shared by every caller (`Platform/AwaitShared.swift`).
- `VideoAd`: what `format(_:)` returns, nothing rendered yet; the facts (`price`, `duration`), `load()` (shared)
  renders it, `reject()` drops it with the `notUsed` beacon; `show(in:)` for overlay and pause, `show(from:)` for
  linear; `dismiss()`; the page's events mapped to beacons and the delegate; `end(_:)` is the only terminal path.
- Format differences live in two places, not in `if format` branches: `Content/ContentRule.swift` (how an ad
  follows the content: `OverlayRule`, `PauseRule`, `NoContentRule`) and `Screen/AdScreen.swift` (where it is
  on screen: `InlineScreen` for overlay and pause, `LinearScreen` for linear). `VideoAd` keeps `show`'s checks,
  the public format guards and `end(_:)`; rules and screens end an ad only through `end(_:)`.
- `Frame/`, the ad's web page and its messages: `FrameMessage` (one page message read: the JSON, the envelope, the
  1 MB limit, the fields, the playhead's bounds; `parse` gives `nil` for a broken envelope), `FrameProtocol` (the
  Kontext Frame Protocol's rules as plain values: the sender, the frame's phase (`FramePhase`, where the ad's frame, its web page, is; not the ad's
  `AdState`: the two move together at fixed points, see `AdState`), the order of the video's events, the error codes,
  a violation once; `accept` returns a `Step`), `TouchGate` (one tap opens one URL), `FrameNavigation` (what a
  top-level navigation may do, a navigation out as a click), `FrameBridge` (its load and timeout, parking, the navigation
  delegate; it carries out each `Step`), `FrameWebView` (the WebView locked down for one ad: what the page may and may not do), `FrameEvent`, `VideoAd+FrameEvents` (what the ad does with each
  message of its page; a click goes to `VideoAd.click`).
- `Screen/`, putting the ad on screen: `AdScreen`, `LinearAdViewController`, `LinearPresentation` (its present and dismiss,
  each with a watchdog), `ScreenSlot` (the app's one ad on screen: taken at `show`, freed at `didEnd`, here and nowhere
  else; the ad holds its screen, the screen its meter; the creative's arrival is `VideoAd.reachedScreen()`), `InlineAdView`, `AdGeometry`, `InlineScreen+Placement` (where an inline ad goes, from `InlineScreen`'s
  insets and chosen size; the page gets the size at `FrameBridge.show(size:)`), `InAppBrowser` (the in-app browser
  a click opens a web link in; the screens treat the ad under it as covered, not ended).
- `Measurement/`, what the viewer saw (visibility, time on screen) and the beacons that report it: `Tracker` (beacons), `TrackingMacros` (a URL's macros filled in), `ViewabilityMeter` (the 50 % rule's loop), `ViewExposure` (how much of a view is seen) and `Polygon` (its geometry), `OnScreenTimeClock`, `SKAdNetworkImpression` (Apple's install-attribution impression of an app-install ad). `Content/`: `ContentPlayer`, `ContentPlayback`, `PlayerOwnership`, `ContentTimeClock` and
  `ContentRule`. `Payloads/` is the ad server's API: /config, /ads, its
  error body, the app's inputs as sent, and Apple attribution; `Model/AdDescriptor` the ad as the SDK keeps it. `State/` is the state of the SDK and of each ad, and their
  legal moves: `SdkLifecycle` and `AdLifecycle` the rules (the phases and the legal moves between them, stateless),
  `SdkState` the SDK's facts (its phase, the public `KontextVideo.State`; the configuration; what `/config` said of
  error and debug reports, which the reporters ask; the app's `user`, `regulatory` and `variantID`), `AdState` every fact of an ad's life: the phase and the milestones
  (loaded, impression, completed, on screen, the failure, whether the video plays); every public flag of `VideoAd` reads it;
  `AdStore` what one `VideoAds` holds (an ad per format, the spent ids, the ad on screen) and the plan an answer makes of
  it (`plan(_:)`, steps over plain ids that `VideoAds` carries out). `Network/` talks to the server: `APIClient`,
  `BeaconClient`, `AdsFetcher` (one ads request at a time per `VideoAds`: the waits, the body, the POST, the failure
  and dropped-ad reports, the kill switch), `ConfigFetcher` (its twin for `/config`: one attempt and its failure
  report). `Diagnostics/IntegrationGuard` holds the checks of the app's integration (initialized, the configuration,
  the content, the user): each stops a debug build, logs and reports. `Device/` what the SDK reads, `Platform/Environment.swift` the
  seams the tests replace, `Platform/LinkOpener` and `LinkRoute` which links open and where (an app, the App Store,
  the in-app browser).

## Glossary

- **view**: a UIKit view (`InlineAdView`, the app's container). **view controller**: a UIKit screen (call UIKit's
  screen this, or "presenter" where that is its role, never "screen"). **screen** (`AdScreen`): where an ad is
  shown, inline in the player (`InlineScreen`) or full screen (`LinearScreen`). **on screen**: visible to the viewer.
- **client**: a transport to one kind of host (`APIClient`, `BeaconClient`). **fetcher**: one server request with a
  purpose, built on a client (`AdsFetcher`, `ConfigFetcher`).

## Rules

- Every file starts with a comment that says, in this order: what it is, in one plain sentence; why it exists or is
  shaped this way, when that is not obvious; a picture or example (an ASCII diagram, a table, real numbers) when the
  idea is spatial, a flow or a decision; where it fits: who uses it and what it hands off to. The main function of a
  file with a multi-step flow gets numbered step comments (`// 1. …`, `// 2. …`). Small, obvious files get only the
  first line. Never repeat what the code says; explain what it cannot. The reference is `Screen/InlineAdView.swift`.
- Commit directly to `main`; no feature branches. Push and watch CI (it runs five jobs; see DEVELOPMENT.md).
- The lifecycle guarantee is sacred: after a successful `show`, exactly one `didEnd`, whoever ended it; nothing is
  delivered through the delegate before `show`. `VideoAd.end(_:)` is the only terminal path.
- One source of truth: every fact of an ad's life is in `AdState` (`State/AdState.swift`), every fact of the SDK's
  in `SdkState` (`State/SdkState.swift`); everything else asks them, never keeps its own copy. A phase moves only
  through `moveTo(_:)`, which asks `AdLifecycle.canMove(from:to:)` or `SdkLifecycle.canMove(from:to:)`; each
  milestone is marked once.
- The page never fires a beacon; `Tracker` does, each entry once, except `click`, `pause`, `resume`, `mute` and
  `unmute`, which fire on every occurrence. The SDK never requests an ad by itself.
- Public API changes go to the Notion page *SDK Lifecycle* first, then the code, then `sdk-kotlin-video`.
- Follow established mobile ad-SDK conventions and modern Apple patterns: `async throws` for one-result
  calls, a delegate for the on-screen moments, public types nested under `KontextVideo` (what the app constructs)
  or `VideoAd` (what it reads off an ad) with `AdFormat` the one top-level exception, internal types top level,
  `TimeInterval` seconds in
  the public API (milliseconds on the wire), enums for closed vocabularies with an `other(String)` escape where the
  page may send its own label.
- `StrictConcurrency` is on and CI fails on any compiler warning in `Sources/`: a concurrency warning is a bug.
  Every type touching UIKit, WebKit or ATT is `@MainActor`.
- Booleans: one that names a state (an adjective or participle) takes `is`/`has`/`was` (`isLoaded`, `hasImpression`,
  `wasOnScreen`); a third-person verb stays (`countsTime`, `refusesShow`); wire keys keep their JSON name (`CodingKeys`).
- Comments say *why*, in prose; a doc comment on every public declaration. No ticket or PR references.
- Facts about the device, consent and attribution come from KontextKit; what the SDK needs and KontextKit lacks
  goes into KontextKit, not into a workaround here.
- Tests: Swift Testing, about 2 minutes for the whole suite, deterministic: no wall-clock bounds a slow CI runner
  breaks. Suites touching process-wide state nest
  under `SerialSuites`; expiry moves the clock (`advanceClock(by:)`), never sleeps; beacon expectations use
  `waitUntil`. A new behavior comes with its test, races included.

## Release

See [RELEASING.md](RELEASING.md): bump `SDKInfo.version` (`Sources/KontextVideoSDK/Payloads/SDKInfo.swift`), add
the `CHANGELOG.md` entry, commit to `main`, push an annotated tag with the same version and no `v` prefix. CI
refuses a tag that does not match `SDKInfo.version`.

## Related repos

- [kontextkit-ios](https://github.com/kontextso/kontextkit-ios): the shared iOS primitives this SDK depends on
- [sdk-kotlin-video](https://github.com/kontextso/sdk-kotlin-video): the Kotlin twin
- `sdk-video-mock-server` (internal, not on GitHub): the ad server stand-in
- [sdk-swift](https://github.com/kontextso/sdk-swift): the chat SDK; the conventions here follow its
