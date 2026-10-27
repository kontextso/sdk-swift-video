# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

Kontext Video SDK for iOS: overlay, pause and linear ads in short-drama and other video-first apps. Swift 5.9,
iOS 14+, Swift Package Manager only (CocoaPods trunk is read-only from December 2026). The contract is the Notion
document *Video Ads API & SDK v2*; the behavior is the Notion page *SDK Lifecycle*, and the code implements it
line by line. Timed mode (windows, `nextRequestAt`) is specified on the Notion pages but deliberately not in the
SDK; the wire's timed-mode fields decode and are ignored. Integration guide for publishers:
https://docs.kontext.so/video/sdk/ios. Kotlin twin: [sdk-kotlin-video](https://github.com/kontextso/sdk-kotlin-video).

## Commands

```bash
xcodebuild build -scheme KontextVideoSDK -destination 'generic/platform=iOS Simulator'
xcodebuild test  -scheme KontextVideoSDK -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro'
```

`swift build` / `swift test` do not work on the host (UIKit, WebKit). The example (`Example/`, XcodeGen) talks to
the mock server `sdk-video-mock-server` on `localhost:5175`; `--demo` runs every flow hands-free. See
[DEVELOPMENT.md](DEVELOPMENT.md).

## Architecture

- `KontextVideo.shared`: initialize (`/config`), `user`, `regulatory`, `variantId`, the one ad on screen.
- `VideoAds`: one per video. `format(_:)` asks the server for all formats with the `VideoAds`'s `sessionId` and the
  ids of the unshown bids it holds (`held`); the server owns the bid state and re-serves held bids until they
  expire; the SDK follows the response. One request at a time, shared by every caller (`Support/AwaitShared.swift`).
- `VideoAd`: what `format(_:)` returns, nothing rendered yet; the facts (`price`, `duration`), `load()` (shared)
  renders it, `reject()` drops it with the `notUsed` beacon; `show(in:)` for overlay and pause, `show()` for
  linear; `dismiss()`; the page's events mapped to beacons and the delegate; `end(_:)` is the only terminal path.
- `Rendering/`: `FrameBridge` (the WebView and the Kontext Frame Protocol), `Tracker` (beacons), `ViewabilityMeter`,
  `LinearViewController`. `Payloads/` is the wire, `Model/AdDescriptor` the ad as the SDK keeps it, `Device/` what the
  SDK reads, `Support/Environment.swift` the seams the tests replace.

## Rules

- Commit directly to `main`; no feature branches. Push and watch CI.
- The lifecycle guarantee is sacred: after a successful `show`, exactly one `didEnd`, whoever ended it; nothing is
  delivered through the delegate before `show`. `VideoAd.end(_:)` is the only terminal path.
- The page never fires a beacon; `Tracker` does, each entry once. The SDK never requests an ad by itself.
- Public API changes go to the Notion page *SDK Lifecycle* first, then the code, then `sdk-kotlin-video`.
- Follow ad-SDK conventions (AdMob, AppLovin MAX, IMA) and modern Apple patterns: `async throws` for one-result
  calls, a delegate for the on-screen moments, public types nested under `KontextVideo` (what the app constructs)
  or `VideoAd` (what it reads off an ad) with `AdFormat` the one top-level exception, internal types top level,
  `TimeInterval` seconds in
  the public API (milliseconds on the wire), enums for closed vocabularies with an `other(String)` escape where the
  page may send its own label.
- `StrictConcurrency` is on: a concurrency warning is a bug. Every type touching UIKit, WebKit or ATT is `@MainActor`.
- Comments say *why*, in prose; a doc comment on every public declaration. No ticket or PR references.
- Facts about the device, consent and attribution come from KontextKit; what the SDK needs and KontextKit lacks
  goes into KontextKit, not into a workaround here.
- Tests: Swift Testing, about 45 s for the whole suite, deterministic. Suites touching process-wide state nest
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
