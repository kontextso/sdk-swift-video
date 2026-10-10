# Releasing

How to cut a release of the **Kontext Video SDK**. Replace `0.1.0` with the version at hand.

> Versions have no `v` prefix, so SPM and CocoaPods agree: `0.1.0`. While the SDK is pre-1.0, a breaking change
> bumps the minor version (`0.2.0`); after 1.0 it bumps the major.

## 1. Check main

1. Checkout `main` and pull.
2. Build the SDK and run the tests (commands in [DEVELOPMENT.md](DEVELOPMENT.md)).
3. Run the example against the mock server (`--demo` runs every flow without touching the screen) and read the
   mock's `/log`: every ad must end with its one `didEnd`, and the beacons must be the spec's.

## 2. Update the changelog

Move the `## Unreleased` entries in `CHANGELOG.md` under a new `## 0.1.0` heading. Breaking changes get a
`### Breaking` section first, with what integrators must do.

```markdown
## 0.2.0
### Breaking
`show(in:)` is gone; the player's view is the container. Conform your player to `KontextVideoPlayer`.

* Add …
* Fix …
```

## 3. Bump the version in three places

They must match; the SDK sends its version with every request.

```
KontextVideoSDK.podspec                          spec.version = '0.1.0'
Sources/KontextVideoSDK/Support/SDKInfo.swift    static let current = SDKInfo(name: "sdk-swift-video", version: "0.1.0")
README.md                                        .package(url: …, from: "0.1.0")
```

## 4. Commit and tag

```bash
git add CHANGELOG.md KontextVideoSDK.podspec Sources/KontextVideoSDK/Support/SDKInfo.swift README.md
git commit -m "Release 0.1.0"
git tag -a 0.1.0 -m "Release 0.1.0"
git push origin main 0.1.0
```

The tag is what SPM resolves; publishers pin to it with `from:` or `exact:`.

## 5. Publish to CocoaPods trunk

```bash
pod spec lint KontextVideoSDK.podspec --allow-warnings
pod trunk push KontextVideoSDK.podspec --allow-warnings
```

## 6. Verify

1. The version appears on https://cocoapods.org/pods/KontextVideoSDK.
2. A fresh project resolves `.package(url: "https://github.com/kontextso/sdk-swift-video.git", exact: "0.1.0")`,
   builds, and runs the README's walkthrough against the production ad server with a `{publisher}-dev` token.
3. Tell the publishers waiting for the release; the changelog entry is the release note.

## Before the first App Store submission that includes the SDK

* `PrivacyInfo.xcprivacy` declares what the SDK collects and the required-reason APIs it uses. It mirrors
  `sdk-swift`; have legal confirm `NSPrivacyTracking` and the data types before a publisher ships.
* An app that lets the SDK show the ATT dialog (`requestTrackingAuthorization: true`) needs
  `NSUserTrackingUsageDescription` in its Info.plist.
