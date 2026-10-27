# Development

For contributors working on the Kontext Video SDK. The integration guide is [docs.kontext.so/video/sdk/ios](https://docs.kontext.so/video/sdk/ios); the contract
is the *Video Ads API & SDK v2* document and its *Video Ads SDK Public API* page in Notion.

## Prerequisites

- macOS 14+ with Xcode 16+.
- An iOS 14+ simulator (Xcode → Window → Devices and Simulators, or `xcrun simctl`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the example project: `brew install xcodegen`.
- Node 20+ and pnpm for the mock ad server, `sdk-video-mock-server` (internal).

The SDK imports UIKit and WebKit, so `swift build` on the host does not work; build and test on a simulator.

## Repository layout

```
sdk-swift-video/
├── Sources/KontextVideoSDK/
│   ├── KontextVideo.swift                          the shared instance: initialize, user, regulatory, variantId
│   ├── VideoAds.swift                              one video's ads: format(_:), the shared request, the session and held bids, destroy, the playhead
│   ├── VideoAd.swift                               one ad: the facts, load() (shared), reject(), show, dismiss, the page's events, the one didEnd
│   ├── VideoAdDelegate.swift, VideoAdError.swift   the on-screen callbacks; what format, load, show, reject and dismiss throw
│   ├── Model/        the model: what the app passes in (Configuration, Content, User, Regulatory, AdFormat) and the ad as the SDK keeps it (AdDescriptor)
│   ├── Network/      talking to the server, any route: APIClient, APIError
│   ├── Payloads/     every body sent or received, named as in the spec: Config and Ads requests and responses, AdPayload (decoded once into AdDescriptor; nothing else reads it), ErrorResponse, SDKInfo
│   ├── Device/       what the SDK reads from the device: DeviceInfo, Privacy (ATT, IFA, the consent merge)
│   ├── Rendering/    the WebView bridge and its events (frame protocol), the linear-ad controller, the tracker, the viewability meter
│   ├── Support/      plumbing: Logger, Environment (the test seams), the debug reporter, awaitShared (work a caller can stop waiting for)
│   └── PrivacyInfo.xcprivacy
├── Tests/KontextVideoSDKTests/   Swift Testing suites, one per source file, plus the whole flows (see Tests)
├── Example/                 SwiftUI app with a real AVPlayer; `project.yml` for XcodeGen, the .xcodeproj is generated
├── .github/workflows/ci.yml the three CI jobs (see CI)
├── Package.swift            SPM manifest; KontextKit pinned exact
├── CLAUDE.md                project context for Claude Code
└── CHANGELOG.md, RELEASING.md
```

The lifecycle these files implement is the Notion page *SDK Lifecycle*: every `format(_:)` asks for all formats
with the `VideoAds`'s `sessionId` and the ids it holds (`held`); the server owns the bid state and re-serves held bids
until they expire; the SDK follows the response. One request and one load at a time, shared by every caller.

The rule for the tree: the root is what the app calls, `Model/` is the model, `Network/` talks to the server, `Payloads/` is what it sends and receives, `Device/` is what the SDK reads from the device, `Rendering/`
is what happens on screen (the Notion hub's "Rendering" section), `Support/` is plumbing.

## Building

```bash
xcodebuild build -scheme KontextVideoSDK -destination 'generic/platform=iOS Simulator'
```

## Running the example

The example talks to the ad server (`server.megabrain.co`, the SDK's default) with a demo token. To run it against
the mock instead, pass `adServerURL: URL(string: "http://localhost:5175")!` in the `Configuration` in
`Example/ExampleApp.swift` and start the mock:

```bash
# In sdk-video-mock-server
pnpm install && pnpm dev

# In sdk-swift-video/Example
xcodegen generate && open Example.xcodeproj      # run on a simulator
```

The home screen lists three videos, one per format. Opening one plays a bundled clip full screen, prepares that
format's ad (`format` then `load`). 3 s in, a linear ad shows over the screen or an overlay inside the player; a
pause ad waits until the viewer taps to pause, a tap resumes, and the next pause gets its own ad. Leaving the screen
calls `destroy()`. The whole integration is `Example/PlayerScreen.swift`.

What to read afterwards:

- The player's bottom line shows the last delegate callback.
- Against the mock, `http://localhost:5175/log` lists every request and beacon, newest first, with the ad id, the query
  (macros already substituted) and a note (`first impression: burl would fire now`, `unknown event`, ...).
- The SDK's log, including debug lines (the subsystem is `so.kontext.video`):

  ```bash
  xcrun simctl spawn <simulator-id> log stream --level debug --predicate 'subsystem == "so.kontext.video"' --style compact
  ```

The mock's README lists the switches a request can flip: a token ending in `-disabled` or `-debug`, a video id
starting with `nofill`, containing `html` or `expires-30`, and so on.

To look inside an ad's page (the DOM, the JS console, the frame protocol messages): Safari → Settings → Advanced →
"Show features for web developers", then Safari → Develop → the simulator → the example app → the frame page.
Xcode's debug builds are inspectable; nothing to configure in the SDK.

## Where things are decided

- The lifecycle, in one line: `load` returns a ready ad; `show` either throws or presentation begins; then zero or
  more interaction callbacks; then exactly one `didEnd`, whoever ended it. Everything in `VideoAd.swift` serves
  that sentence; `end(_:)` is the only terminal path.
- The page never fires a beacon; `Tracker` fires every entry once, from the places in `VideoAd.handle(_:)`.
- WebKit loads a video's data only for a WebView that is in a window, so `FrameBridge` parks a loading WebView
  invisibly in the key window and hands it over with `takeWebView()` at show.
- Every public class is `@MainActor`; `deinit`s hop to the main actor for their cleanup.

## Code style

- Swift 5.9, iOS 14+. `StrictConcurrency` is on in `Package.swift`: a concurrency warning is a bug, fix it
  before committing; it is what a publisher building in Swift 6 language mode would see as an error.
- Every type that touches UIKit, WebKit or ATT is `@MainActor`; `deinit`s hop to the main actor for their cleanup.
- Comments say *why*, in prose, not what: a doc comment on every public declaration and on every internal one
  whose reason is not obvious from its name. No references to tickets or PRs.
- Nesting: a public type the app constructs nests under `KontextVideo` (`Configuration`, `Content`, `User`,
  `Regulatory`), so it never collides with the app's own `User` or `Content` and `.init(…)` works where the type
  is inferred; a public type the app reads off an ad nests under `VideoAd` (`Price`, `Click`, `EndReason`,
  `RejectReason`); a type that exists only inside an error nests under `VideoAdError` (`NoFillReason`). Internal
  types are top level: nesting protects app code from collisions, and internal
  types cannot collide. `AdFormat` is the one public top-level type: it names the formats everywhere and
  cannot realistically collide.
- Public API changes go to the Notion page *SDK Lifecycle* first, then here, then to `sdk-kotlin-video`.
- No linter yet; `xcodebuild` warnings are the signal and the build is kept at zero.

## Tests

Swift Testing, run on a simulator (the SDK imports UIKit and WebKit):

```bash
xcodebuild test -scheme KontextVideoSDK -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro'

# One suite, or with coverage
xcodebuild test -scheme KontextVideoSDK -destination '…' -only-testing:KontextVideoSDKTests/SerialSuites/VideoAdTests
xcodebuild test -scheme KontextVideoSDK -destination '…' -enableCodeCoverage YES -resultBundlePath cov.xcresult
xcrun xccov view --report --files-for-target KontextVideoSDK cov.xcresult
```

Layout, one suite per source file plus the whole flows:

```
Tests/KontextVideoSDKTests/
├── Helpers/      StubServer (a scripted ad server behind URLProtocol), Fixtures (payloads),
│                 FramePageServer (real frame pages over the kontext-test scheme), TestSupport
│                 (TestPlayer, RecordingDelegate, TestWindow, SDKHarness, waitUntil), SerialSuites
├── Model/        encoding of what the app passes in
├── Network/      the client: transport, status codes, the error body
├── Payloads/     decoding the answers, building the requests (device facts, consent and ATT included)
├── Rendering/    the bridge's state machine, the tracker, the meter, the linear-ad controller
├── Core/         KontextVideo, VideoAds, VideoAd (before show and on screen), support, the debug reporter
└── Integration/  a real WKWebView loading real pages, the API and beacons stubbed: every flow end to end
```

Rules the suites follow:

- Anything that touches process-wide state (the shared instance, `Environment`, the stub server) nests under
  `SerialSuites`, which is `.serialized`; Swift Testing runs other suites in parallel.
- `SDKHarness` resets everything before a test and installs the stub server; the seams it uses are in
  `Support/Environment.swift`, and production never sets them.
- Expectations on beacons use `waitUntil`: beacons are fire-and-forget and arrive a moment after the call.
- Expiry is never waited for: `advanceClock(by:)` moves `Environment.now`, the ad clock. A test that sleeps to
  let something expire is flaky on a slow runner and goes against the suite's budget, about 45 s in all.
- The stub server routes each session's requests to the server that created it, so a beacon a previous test's
  `VideoAds` fires from `deinit` never lands in the next test's recordings.

What the package runner cannot do, and where it is covered instead: there is no `UIWindowScene`, so UIKit never
completes a modal transition (`present` never calls back), and the ATT dialog cannot appear. The linear ad
tests therefore assert what the SDK asked UIKit to do and drive the controller's disappearance decision directly;
the example app against the mock covers the real presentation and dismissal.

## CI

`.github/workflows/ci.yml` runs on every push and pull request, on `macos-15` with Xcode 16.4:

- **Example app**: `xcodegen generate` and a build of `Example/` against the local SDK. It is what catches a
  public API change that breaks a real integration.
- **Test**: `xcodebuild test` on the SDK target, iPhone 16 / iOS 18.5.
- **Release tag matches SDKInfo.version**: on a tag push only; fails when the tag and `SDKInfo.version` differ.

## Cross-SDK consistency

The Kotlin twin is [sdk-kotlin-video](https://github.com/kontextso/sdk-kotlin-video): the same formats, the same
lifecycle (the Notion page *SDK Lifecycle*), the same wire contract, and file-structure parity where the languages
allow it (`VideoAds.swift` / `VideoAds.kt`, `VideoAd.swift` / `VideoAd.kt`, ...). When adding or renaming a public
type, match the Kotlin counterpart, or leave a comment saying why not. The server both talk to is mocked by
`sdk-video-mock-server` (internal).

## KontextKit dependency

Device, privacy (ATT, IFA, the IAB consent keys) and StoreKit facts come from
[KontextKit](https://github.com/kontextso/kontextkit-ios), pinned to an exact version in `Package.swift` while it
is pre-1.0; the SDK uses its `KontextKit` product only, not the Open Measurement xcframework. What the SDK needs
and KontextKit lacks goes into KontextKit, not into a workaround here. To build against an unreleased KontextKit,
point `Package.swift` at a sibling checkout and revert before committing:

```swift
.package(path: "../kontextkit-ios"),
```

