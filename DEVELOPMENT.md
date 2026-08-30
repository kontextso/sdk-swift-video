# Development

This guide is for contributors working on the Kontext Video SDK locally.

## Prerequisites

- **macOS 14+** with **Xcode 16.0+**
- **iOS Simulator** or a physical device for the example app
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** for regenerating the example app `.xcodeproj` from `project.yml`. Install: `brew install xcodegen`.

The SDK itself is a Swift Package — `swift build` won't work on host macOS because the library imports `UIKit`; build and test against the iOS Simulator instead.

## Repository layout

```
sdk-swift-video/
├── Sources/KontextVideoSDK/         # SDK source (entry points, models, networking, UI)
├── Example/                         # SwiftUI short-drama demo app (XcodeGen)
│   ├── project.yml                  # XcodeGen input
│   └── Example/                     # app sources
├── Package.swift                    # SPM manifest
├── KontextVideoSDK.podspec          # CocoaPods manifest (alternative distribution)
├── CLAUDE.md                        # Claude Code project context
└── RELEASING.md                     # how to cut a release
```

## Building the SDK

```bash
xcodebuild build \
  -scheme KontextVideoSDK \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro' \
  -skipPackagePluginValidation
```

There is no test suite yet — the contract is still moving; iterate against the
mock server instead.

## Mock ad server

The real `/preload` endpoint does not exist yet. Development runs against
[sdk-video-mock-server](https://github.com/kontextso/sdk-video-mock-server):

```bash
git clone git@github.com:kontextso/sdk-video-mock-server.git
cd sdk-video-mock-server && pnpm i && pnpm dev   # http://localhost:5175
```

The example app is pointed at `http://localhost:5175` (`Example/Ads.swift`);
edit `mocks/preload.json` in the mock repo to change what the app renders.

## Running the example app

```bash
cd Example
xcodegen generate   # only after changing project.yml
open Example.xcodeproj
```

Run the `Example` scheme. For CI/screenshot automation, launching with `SIMCTL_CHILD_AUTO_OPEN_STORY=1` jumps straight into the player; add `SIMCTL_CHILD_AUTO_PAUSE_LOOP=1` to pause/resume every 3 s so the pause → ad → resume → reload cycle shows up in the console (each `shown` carries a different `bidId`).
