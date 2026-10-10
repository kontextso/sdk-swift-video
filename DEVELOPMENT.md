# Development

For contributors working on the Kontext Video SDK. The integration guide is the [README](README.md); the contract
is the *Video Ads API & SDK v2* document and its *Video Ads SDK Public API* page in Notion.

## Prerequisites

- macOS 14+ with Xcode 16+.
- An iOS 14+ simulator (Xcode → Window → Devices and Simulators, or `xcrun simctl`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the example project: `brew install xcodegen`.
- Node 20+ and pnpm for the mock ad server, [sdk-video-mock-server](https://github.com/kontextso/sdk-video-mock-server).

The SDK imports UIKit and WebKit, so `swift build` on the host does not work; build and test on a simulator.

## Repository layout

```
sdk-swift-video/
├── Sources/KontextVideoSDK/
│   ├── KontextVideo.swift, Configuration.swift     the shared instance and its options
│   ├── VideoAds.swift, VideoAd.swift               one video's ads; one ad
│   ├── VideoAdDelegate.swift, VideoAdError.swift   the lifecycle callbacks; what load and show throw
│   ├── Placements.swift                            overlay / pause / interstitial placements
│   ├── Model/        what the app passes in: Content, User, Regulatory, Options, the player protocol and adapter
│   ├── API/          the wire: requests, responses, the ad payload, device info, privacy, the client
│   ├── Frame/        rendering: the WebView bridge, the interstitial controller, the tracker, the viewability meter
│   ├── Support/      Logger, SDKInfo, the debug reporter
│   └── PrivacyInfo.xcprivacy
├── Example/                 SwiftUI app with a real AVPlayer; `project.yml` for XcodeGen
├── Package.swift            SPM manifest
├── KontextVideoSDK.podspec  CocoaPods manifest
├── CHANGELOG.md, RELEASING.md
└── KontextKit-v2-updates.md what the next KontextKit should change, and where this SDK works around it
```

The rule for the tree: the root is what the app calls, `Model/` is what it passes in, `API/` is the wire, `Frame/`
is rendering, `Support/` is plumbing.

## Building

```bash
xcodebuild build -scheme KontextVideoSDK -destination 'generic/platform=iOS Simulator'
```

## Running the example against the mock server

The example talks to `http://localhost:5175`, which is where the mock listens.

```bash
# In sdk-video-mock-server
pnpm install && pnpm dev

# In sdk-swift-video/Example
xcodegen generate && open Example.xcodeproj      # run on a simulator
```

`--demo` as a launch argument runs every flow without touching the screen: a pause ad shown and dismissed, an
overlay, an interstitial interrupted from outside, an ad dropped without being shown, and `destroy()` with an ad
on screen. From a terminal:

```bash
xcrun simctl launch <simulator-id> so.kontext.example-video --demo
```

What to read afterwards:

- The example's screen lists every delegate callback.
- The mock's `http://localhost:5175/log` lists every request and beacon, newest first, with the ad id, the query
  (macros already substituted) and a note (`first impression: burl would fire now`, `unknown event`, ...).
- The SDK's log, including debug lines (the subsystem is `so.kontext.video`):

  ```bash
  xcrun simctl spawn <simulator-id> log stream --level debug --predicate 'subsystem == "so.kontext.video"' --style compact
  ```

The mock's README lists the switches a request can flip: a token ending in `-disabled` or `-debug`, a video id
starting with `nofill`, a placement id ending in `-disabled`, and so on.

## Where things are decided

- The lifecycle, in one line: `load` returns a ready ad; `show` either throws or presentation begins; then zero or
  more interaction callbacks; then exactly one `didEnd`, whoever ended it. Everything in `VideoAd.swift` serves
  that sentence; `end(_:)` is the only terminal path.
- The page never fires a beacon; `Tracker` fires every entry once, from the places in `VideoAd.handle(_:)`.
- WebKit loads a video's data only for a WebView that is in a window, so `FrameBridge` parks a loading WebView
  invisibly in the key window and hands it over with `takeWebView()` at show.
- Every public class is `@MainActor`; `deinit`s hop to the main actor for their cleanup.

## Tests

```bash
xcodebuild test -scheme KontextVideoSDK -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro'
```
