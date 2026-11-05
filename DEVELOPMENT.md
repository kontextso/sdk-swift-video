# Development

For contributors working on the Kontext Video SDK. The integration guide is [docs.kontext.so/video/sdk/swift](https://docs.kontext.so/video/sdk/swift); the contract
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
│   ├── KontextVideo.swift                          the shared instance: initialize, user, regulatory, variantID
│   ├── VideoAds.swift                              one video's ads: format(_:), the shared request, the session and held bids, destroy, the playhead
│   ├── VideoAd.swift                               one ad: the facts, load() (shared), reject(), show, dismiss, the one didEnd
│   ├── VideoAdDelegate.swift, VideoAdError.swift   the on-screen callbacks; what format, load and show throw
│   ├── KontextVideoSDK.docc                       the DocC catalog: the landing page of the API reference
│   ├── Model/        the model: what the app passes in (Configuration, Content, User, Regulatory, AdFormat), the public types alone (their rules live in Payloads/AppInputs, the configuration check next to initialize) and the ad as the SDK keeps it (AdDescriptor)
│   ├── State/        the state of the SDK and of each ad, and their legal moves: SdkLifecycle and AdLifecycle (the phases and the moves between them, stateless), SdkState (the SDK's phase, its configuration, what /config said of the reports) and AdState (every fact of an ad's life, its phase, its milestones and the flags they give), AdStore (what one VideoAds holds, and the plan an answer makes of it)
│   ├── Network/      HTTP: APIClient (our server, any route), AdsFetcher (one ads request at a time per VideoAds), BeaconClient (tracking GETs), RedirectLimit (10 redirects at most), APIError
│   ├── Payloads/     every body sent or received, named as in the spec: Config and Ads requests and responses, AdPayload (decoded once into AdDescriptor; nothing else reads it), AppInputs (how the app's Content, User and Regulatory go on the wire, and the request's rules for them: what is left out, a COPPA user; the public types are not Codable), ErrorResponse, SDKInfo
│   ├── Device/       what the SDK reads from the device: DeviceInfo (the device facts, no state), UserAgent (the user agent's shared lookup, its wait and its fallback), Privacy (ATT, IFA, the consent merge)
│   ├── Frame/        the ad's web page and its messages: FrameMessage (one page message read: the envelope and its fields), FrameProtocol (the protocol's rules: accept(message) → Step; the frame's phase, FramePhase: where the ad's frame, its web page, is), TouchGate (one tap, one URL), FrameNavigation (the page's navigations), FrameBridge (carries out each Step), FrameWebView (the WebView locked down for one ad) and its events, VideoAd+FrameEvents (what the ad does with each message), the SKAdNetwork impression
│   ├── Screen/       putting the ad on screen: AdScreen (InlineScreen for overlay and pause, with the app's insets and the chosen size; LinearScreen for linear), LinearAdViewController and its presentation, ScreenSlot (the app's one ad on screen, taken at show and freed at didEnd), InlineAdView (what an overlay or pause ad puts into the player's view), InlineScreen+Placement (where an overlay or pause ad goes, on InlineScreen)
│   ├── Measurement/  what the viewer saw (visibility, time on screen) and the beacons that report it: the tracker (beacons) and its macros, the viewability meter, what a view exposes and its geometry, the on-screen time clock
│   ├── Content/      the app's content player: ContentPlayer (the public protocol and its defaults), ContentPlayback (the tracked player), PlayerOwnership (a player belongs to one VideoAds at a time), ContentTimeClock (an overlay's video time, the twin of OnScreenTimeClock), ContentRule (how each format follows it; OverlayRule and PauseRule in their own files, NoContentRule)
│   ├── SwiftUI/      VideoAdHost: show an ad from SwiftUI by setting it (a UIViewRepresentable over a pass-through view)
│   ├── Diagnostics/  what the SDK tells: Logger (the console); ErrorReporter (faults to /v2/error: the mode, scheduling, retries, the server's answers), ErrorReport (one report: its vocabulary and fields), ReportQueue (the waiting reports and their batches, pure); DebugReporter (debug events to /v2/debug), EventHistory (the last events, an error report's history); ReportFormat (capping, the timestamp, a state value), shared so neither reporter reaches into the other
│   ├── Platform/     the SDK's ground: Environment (the seams tests replace), awaitShared (work a caller can stop waiting for), LinkOpener (which links an ad may open, and opening them)
│   └── PrivacyInfo.xcprivacy
├── Sources/KontextVideoTTSDK/   the optional KontextVideoTTSDK product: ads.track(ttVideoEngine:), TTSDK read through Objective-C (see its README)
├── Tests/KontextVideoSDKTests/   Swift Testing suites, one per source file, plus the whole flows (see Tests)
├── Example/                 SwiftUI app with a real AVPlayer; `project.yml` for XcodeGen, the .xcodeproj is generated
├── .github/workflows/      ci.yml, the five CI jobs; release-consumer.yml, the release as a publisher resolves it (see CI)
├── Extras/ReleaseCheck/     a publisher's package on the released tag, built by release-consumer.yml (see its README)
├── Package.swift            SPM manifest; KontextKit up to the next minor
├── AGENTS.md                guidance for coding agents (CLAUDE.md only imports it)
└── CHANGELOG.md, RELEASING.md
```

The lifecycle these files implement is the Notion page *SDK Lifecycle*: every `format(_:)` asks for all formats
with the `VideoAds`'s `sessionId` and the ids it holds (`held`); the server owns the bid state and re-serves held bids
until they expire; the SDK follows the response. One request and one load at a time, shared by every caller.

The rule for the tree: the root is what the app calls, `Model/` is the model, `State/` is the state of the SDK and of each ad and their legal moves, `Network/` talks to the server, `Payloads/` is what it sends and receives, `Device/` is what the SDK reads from the device, `Frame/` is the ad's
web page and its messages, `Screen/` puts the ad on screen, `Measurement/` is what the viewer saw (visibility, time on screen) and the beacons that report it (together the Notion hub's "Rendering" section), `Diagnostics/` is what the SDK tells (logs, error and debug reports), `Platform/` the system calls and seams under the rest.

## Building

```bash
xcodebuild build -scheme KontextVideoSDK-Package -destination 'generic/platform=iOS Simulator'

# The API reference: the doc comments and the DocC catalog (KontextVideoSDK.docc); it must build without warnings
xcodebuild docbuild -scheme KontextVideoSDK -destination 'generic/platform=iOS Simulator'
```

## Running the example

The example talks to the ad server (`server.megabrain.co`, the SDK's default) with a demo token. To run it against
the mock instead, pass `adServerURL: URL(string: "http://localhost:5175")!` in the `Configuration` in
`Example/Example/ExampleApp.swift` and start the mock:

```bash
# In sdk-video-mock-server
pnpm install && pnpm dev

# In sdk-swift-video/Example
xcodegen generate && open Example.xcodeproj      # run on a simulator
```

The home screen lists four videos: an inline and a full-screen pause ad, an overlay and a linear ad. Opening one plays a bundled clip full screen, prepares that
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

- The lifecycle, in one line: `load` returns a ready ad; `show` either throws or the ad begins to show; then zero or
  more interaction callbacks; then exactly one `didEnd`, whoever ended it. Everything in `VideoAd.swift` serves
  that sentence; `end(_:)` is the only terminal path.
- One source of truth: every fact of an ad's life (phase, loaded, impression, completed, on screen, the failure) is
  in `State/AdState`; everything else asks it. `VideoAd`'s public flags are getters over it. Its phase moves only
  through `moveTo(_:)`, under the stateless rules of `State/AdLifecycle`. The SDK's own facts (its phase, the
  public `KontextVideo.State`; the configuration; what `/config` said of error and debug reports) are in
  `State/SdkState` the same way, moved by `KontextVideo` under `State/SdkLifecycle`; the reporters ask it.
- What differs by format lives in two places: `Content/ContentRule.swift` (how the ad follows the content) and
  `Screen/AdScreen.swift` (where it is on screen and how it leaves). `VideoAd` keeps the rest: `show`'s
  checks, the public format guards (`wrongShowMethod`, `dismiss()` on a linear ad) and the facts of the linear
  format (its video's duration for the page, a close before `complete` is a skip). A new format difference
  goes into a rule or a screen, not into an `if format` in `VideoAd`.
- Pure rules sit apart from the code that acts on them ("functional core, imperative shell"), each with a table
  test: `State/SdkLifecycle` (which SDK phase may follow which), `State/AdLifecycle` (which phase may follow which; `AdState` moves only when it allows, each milestone once; `VideoAd` acts on each move), `Frame/FrameMessage` (how a
  page message is read), `Frame/FrameProtocol` (what each page message means in each state; `FrameBridge` carries out the `Step`), `FrameEvent.CloseReason.outcome`
  (the beacon and end reason of a page's close), and the decision table in `Content/ContentRule.swift`.
- The page never fires a beacon; `Tracker` fires every entry once (through `BeaconClient`), except `click`, `pause`, `resume`, `mute` and
  `unmute`, which fire on every occurrence, from the places in `VideoAd.handle(_:)`.
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
- Booleans, the same names as in `sdk-kotlin-video`: a state (an adjective or participle) takes `is`, `has` or
  `was` (`isLoaded`, `isStopped`, `hasImpression`, `hasEnded`, `wasOnScreen`); a third-person verb stays as it is
  (`countsTime`, `checksEpisode`, `refusesShow`, `coversWhole`). A wire field renamed in Swift keeps its JSON key
  through `CodingKeys` (`isMuted` is sent as `muted`); wire and standard names (`gdpr`, `coppa`, `reportErrors`)
  and UIKit's overrides stay.
- Public API changes go to the Notion page *SDK Lifecycle* first, then here, then to `sdk-kotlin-video`.
- SwiftLint (`.swiftlint.yml`, stricter limits relaxed for `Tests/`) and `swiftlint analyze` run in CI, and CI fails
  on any compiler warning in `Sources/`; the commands are in AGENTS.md.

## Tests

Swift Testing, run on a simulator (the SDK imports UIKit and WebKit):

```bash
xcodebuild test -scheme KontextVideoSDK-Package -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro'

# One suite, or with coverage
xcodebuild test -scheme KontextVideoSDK-Package -destination '…' -only-testing:KontextVideoSDKTests/SerialSuites/VideoAdTests
xcodebuild test -scheme KontextVideoSDK-Package -destination '…' -enableCodeCoverage YES -resultBundlePath cov.xcresult
xcrun xccov view --report --files-for-target KontextVideoSDK cov.xcresult
```

Layout, one suite per source file plus the whole flows:

```
Tests/KontextVideoSDKTests/
├── Helpers/      StubServer (a scripted ad server behind URLProtocol), Fixtures (payloads),
│                 FramePageServer (real frame pages over the kontext-test scheme), FramePageDriver (the
│                 bridge's calls on the protocol, without a WebView), TestSupport
│                 (TestPlayer, RecordingDelegate, TestWindow, SDKHarness, waitUntil), SerialSuites
├── Model/        encoding of what the app passes in
├── State/        the lifecycles' tables (SdkLifecycleTests, AdLifecycleTests), the SDK state's and the ad state's moves,
│                 milestones and flags (SdkStateTests, AdStateTests), every SDK move and the reporters across them
│                 end to end (SdkStatesTests), what an ads answer does to the held ads (AdStoreTests)
├── Network/      the client: transport, status codes, the error body
├── Device/       the user agent's fallback (UserAgentTests)
├── Payloads/     decoding the answers, building the requests (device facts, consent and ATT included);
│                 CorpusTests runs the shared malformed-answer corpus
├── Corpus/       a copy of the video-sdk-corpus repo (internal), written by its sync.sh: never edit it
│                 here; its README has the format and how to add a case
├── Frame/        a page message read (FrameMessageTests), the protocol as tables (FrameProtocolTableTests) and rule by
│                 rule (FrameProtocolTests), every message in every state (FrameMessageTableTests), the navigations (FrameNavigationTests), one tap
│                 one URL (TouchGateTests), all without a
│                 WebView; the bridge with its WebView (FrameBridgeTests)
├── Screen/       the linear-ad controller (LinearAdViewControllerTests)
├── Measurement/  the tracker, its macros (TrackingMacrosTests), the meter, its geometry (PolygonTests), the on-screen time clock
├── Core/         KontextVideo, VideoAds, VideoAd (before show and on screen)
├── Diagnostics/  the logger, the error reporter, the report queue (ReportQueueTests), the event history
│                 (EventHistoryTests), the debug reporter
├── Platform/     the environment's seams, awaitShared, the link opener
└── Integration/  a real WKWebView loading real pages, the API and beacons stubbed: every flow end to end
```

Rules the suites follow:

- A test that checks the frame protocol's rules drives `FramePageDriver`, not a `FrameBridge`: every bridge owns
  a WKWebView, and WebKit launches a web content process for each. A burst of them on a CI runner stalled the
  suites after it that load real pages.

- Anything that touches process-wide state (the shared instance, `Environment`, the stub server) nests under
  `SerialSuites`, which is `.serialized`; Swift Testing runs other suites in parallel.
- `SDKHarness` resets everything before a test and installs the stub server; the seams it uses are in
  `Platform/Environment.swift`, and production never sets them.
- Expectations on beacons use `waitUntil`: beacons are fire-and-forget and arrive a moment after the call.
- Expiry is never waited for: `advanceClock(by:)` moves `Environment.now`, the ad clock. A test that sleeps to
  let something expire is flaky on a slow runner and goes against the suite's budget, about 2 minutes in all.
- The stub server routes each session's requests to the server that created it, so a beacon a previous test's
  `VideoAds` fires from `deinit` never lands in the next test's recordings.

What the test runner cannot do, and where it is covered instead: its windows belong to a scene, but UIKit never
completes a modal transition there (`present` never calls back), and the ATT dialog cannot appear (the tests
answer through `Environment`'s ATT seams). The linear ad
tests therefore assert what the SDK asked UIKit to do and drive the controller's disappearance decision directly;
the example app against the mock covers the real presentation and dismissal.

## CI

`.github/workflows/ci.yml` runs on pushes to `main`, on tags and on pull requests, on `macos-15` with Xcode 16.4:

- **SwiftLint**: `swiftlint lint --strict`, a clean build whose log must hold no compiler warning in
  `Sources/KontextVideoSDK` (the compiler's notes are printed when it does), then `swiftlint analyze --strict`.
- **Example app**: `xcodegen generate` and a build of `Example/` against the local SDK. It is what catches a
  public API change that breaks a real integration.
- **Test**: `xcodebuild test` on the SDK target, iPhone 16 / iOS 18.5. A test-host restart counts as a failure.
- **Test (iOS 15)**: the same tests on an iPhone 13 with iOS 15.5, downloaded from Apple on every run. iOS 14, the
  SDK's minimum, cannot run on GitHub's runners: macos-14, the last image with Xcode 15, is retired, and Xcode
  16 and 26 run iOS 15 or later simulators only. iOS 15.5 is the oldest a runner can test.
- **Release tag matches SDKInfo.version**: on a tag push only; fails when the tag and `SDKInfo.version` differ,
  or when `CHANGELOG.md` has no `## <tag>` section.

`.github/workflows/release-consumer.yml` builds `Extras/ReleaseCheck`, a package that depends on the SDK by git
URL and `exact:` the tag, for a device with Xcode 16.0 (the oldest Xcode on the runner). It runs on a tag push
and by hand (Actions → Release consumer → Run workflow, with the tag), never on `main` or pull requests: before
the tag is on GitHub there is nothing to resolve.

## What a publisher needs

From `Package.swift` and the CI above:

- iOS 14 or later as the app's deployment target (`platforms: [.iOS(.v14)]`, KontextKit's too); tested down to
  iOS 15.5, the oldest simulator a runner can run.
- Xcode 16.0 or later: the release-consumer build uses Xcode 16.0, CI uses 16.4. The manifest's
  `swift-tools-version` is 5.9 (Swift 5 language mode, so an app in Swift 5 or 6 mode can use it), but no job
  builds with Xcode 15, so it is not promised.
- Swift Package Manager (no CocoaPods), resolving `https://github.com/kontextso/sdk-swift-video.git` and
  `https://github.com/kontextso/kontextkit-ios.git` (pinned exact by the SDK).

## Cross-SDK consistency

The Kotlin twin is [sdk-kotlin-video](https://github.com/kontextso/sdk-kotlin-video): the same formats, the same
lifecycle (the Notion page *SDK Lifecycle*), the same wire contract, and file-structure parity where the languages
allow it (`VideoAds.swift` / `VideoAds.kt`, `VideoAd.swift` / `VideoAd.kt`, ...). When adding or renaming a public
type, match the Kotlin counterpart, or leave a comment saying why not.

Where the two differ on purpose, each language's convention wins:

- Initialisms: Swift cases them as Swift does (`variantID`, `lastRequestID`, `gppSID`), Kotlin keeps `Id`.
- `dismiss()` does not throw (Kotlin drops its checked exception the same way); `reject(_:)` does not throw
  in Swift, where an ad already ended or shown makes it a no-op with a console line.
- The custom player: Swift's `ContentPlayer` reports through optional publishers (`isPlayingPublisher`,
  `seekPublisher`, `contentChangedPublisher`) and `playbackSpeed`; Kotlin's through a `Listener`
  (`onIsPlayingChanged`, `onSeek`, `onContentChanged`) and `playbackSpeed`. Same meaning, member for member.
- The public value types are plain values in Swift, not `Codable`: the wire goes through `Payloads/AppInputs.swift`. The server both talk to is mocked by
`sdk-video-mock-server` (internal).

## KontextKit dependency

Device, privacy (ATT, IFA, the IAB consent keys) and StoreKit facts come from
[KontextKit](https://github.com/kontextso/kontextkit-ios), pinned up to the next minor version in `Package.swift` while it
is pre-1.0 (patches are taken, a minor release may break); the SDK uses its `KontextKit` product only, not the Open Measurement xcframework. What the SDK needs
and KontextKit lacks goes into KontextKit, not into a workaround here. To build against an unreleased KontextKit,
point `Package.swift` at a sibling checkout and revert before committing:

```swift
.package(path: "../kontextkit-ios"),
```

