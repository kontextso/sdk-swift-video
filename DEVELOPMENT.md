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
├── Sources/KontextVideoSDK/         # SDK source (entry points, models, networking)
├── Tests/KontextVideoSDKTests/      # XCTest suite
├── Example/                         # SwiftUI short-drama demo app (XcodeGen)
│   ├── project.yml                  # XcodeGen input
│   └── Example/                     # app sources
├── Package.swift                    # SPM manifest
├── KontextVideoSDK.podspec          # CocoaPods manifest (alternative distribution)
├── CLAUDE.md                        # Claude Code project context
└── RELEASING.md                     # how to cut a release
```

## Building & testing the SDK

```bash
xcodebuild build \
  -scheme KontextVideoSDK \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro' \
  -skipPackagePluginValidation

xcodebuild test \
  -scheme KontextVideoSDK \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro' \
  -skipPackagePluginValidation
```

## Running the example app

```bash
cd Example
xcodegen generate   # only after changing project.yml
open Example.xcodeproj
```

Run the `Example` scheme. For CI/screenshot automation, launching with `SIMCTL_CHILD_AUTO_OPEN_STORY=1` jumps straight into the player.
