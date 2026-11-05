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
the ad server by default, or the mock `sdk-video-mock-server` on `localhost:5175` through `adServerURL`: four videos (two pause, one
overlay, one linear); the overlay and linear ads show 3 s in, a pause ad when the viewer pauses. See
[DEVELOPMENT.md](DEVELOPMENT.md).

## Architecture

- `KontextVideo.shared`: initialize (`/config`), `user`, `regulatory`, `variantID`, the one ad on screen; the shell
  that moves `SdkState`.
- `VideoAds`: one per video. `format(_:)` asks the server for all formats with the `VideoAds`'s `sessionId` and the
  ids of the unshown bids it holds (`held`); the server owns the bid state and re-serves held bids until they
  expire; the SDK follows the response. One request at a time, shared by every caller (`Platform/AwaitShared.swift`).
- `VideoAd`: what `format(_:)` returns, nothing rendered yet; the facts (`price`, `duration`), `load()` (shared)
  renders it, `reject()` drops it with the `notUsed` beacon; `show(in:)` for overlay and pause, `show()` for
  linear; `dismiss()`; the page's events mapped to beacons and the delegate; `end(_:)` is the only terminal path.
- Format differences live in two places, not in `if format` branches: `Content/ContentRule.swift` (how an ad
  follows the content: `OverlayRule`, `PauseRule`, `NoContentRule`) and `Screen/AdScreen.swift` (where it is
  on screen: `InlineScreen` for overlay and pause, `LinearScreen` for linear). `VideoAd` keeps `show`'s checks,
  the public format guards and `end(_:)`; rules and screens end an ad only through `end(_:)`.
- `Frame/`, the ad's web page and its messages: `FrameMessage` (one page message read: the JSON, the envelope, the
  1 MB limit, the fields, the playhead's bounds; `parse` gives `nil` for a broken envelope), `FrameProtocol` (the
  Kontext Frame Protocol's rules as plain values: the sender, the page's state (`PageState`, not the ad's
  `AdState`: the two move together at fixed points, see `FrameProtocol`), the order of the video's events, one URL
  per touch, the navigation decision; `accept` returns a `Step`), `FrameBridge` (the WebView, its load and timeout, parking, the
  WebKit delegates; it carries out each `Step`), `FrameEvent`, `VideoAd+FrameEvents` (what the ad does with each
  message of its page; a click goes to `VideoAd.click`), `SKAdNetworkImpression`.
- `Screen/`, putting the ad on screen: `AdScreen`, `LinearAdViewController`, `LinearPresentation` (its present and dismiss,
  each with a watchdog), `ShownAd` (the ad on screen: the slot, the screen, the meter; `begin` takes the slot, the
  creative's arrival is `VideoAd.reachedScreen()`), `InlineAdView`, `AdGeometry`, `VideoAd+Placement` (where an inline ad goes, from `InlineScreen`'s
  insets and chosen size; the page gets the size at `FrameBridge.show(size:)`).
- `Measurement/`, measuring and reporting: `Tracker` (beacons), `TrackingMacros` (a URL's macros filled in), `ViewabilityMeter` (the 50 % rule's loop), `ViewExposure` (how much of a view is seen) and `Polygon` (its geometry), `ActiveTimeClock`. `Content/`: `ContentPlayer`, `ContentPlayback`, `PlayerOwnership`, `ContentTimeClock` and
  `ContentRule`. `Payloads/` is the
  wire, `Model/AdDescriptor` the ad as the SDK keeps it. `State/` is the state of the SDK and of each ad, and their
  legal moves: `SdkLifecycle` and `AdLifecycle` the rules (the phases and the legal moves between them, stateless),
  `SdkState` the SDK's facts (its phase, the public `KontextVideo.State`; the configuration; what `/config` said of
  error and debug reports, which the reporters ask), `AdState` every fact of an ad's life: the phase and the milestones
  (loaded, impression, completed, on screen, the failure); every public flag of `VideoAd` reads it. `Device/` what the SDK reads, `Platform/Environment.swift` the
  seams the tests replace.

## Rules

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
