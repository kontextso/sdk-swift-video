# Releasing

How to cut a release of the **Kontext Video SDK**. Replace `0.1.0` with the version at hand.

> Versions have no `v` prefix: `0.1.0`. While the SDK is pre-1.0, a breaking change bumps the minor version
> (`0.2.0`); after 1.0 it bumps the major. The SDK ships through Swift Package Manager only: CocoaPods trunk
> stops accepting new versions on December 2, 2026.

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

## 3. Bump the version

One place: `SDKInfo.version` in `Sources/KontextVideoSDK/Payloads/SDKInfo.swift`. The SDK sends it with every request,
and CI refuses a release tag that does not match it. The docs page's
`from: "0.1.0"` means "that version or newer" and stays as it is.

```
Sources/KontextVideoSDK/API/SDKInfo.swift    static let version = "0.1.0"
```

## 4. Commit and tag

```bash
git add CHANGELOG.md Sources/KontextVideoSDK/Payloads/SDKInfo.swift
git commit -m "Release 0.1.0"
git tag -a 0.1.0 -m "Release 0.1.0"
git push origin main 0.1.0
```

The tag is what SPM resolves; publishers pin to it with `from:` or `exact:`. The push of the tag runs the
`release-tag` CI job, which fails if the tag and `SDKInfo.version` differ.

## 5. Verify

1. A fresh project resolves `.package(url: "https://github.com/kontextso/sdk-swift-video.git", exact: "0.1.0")`,
   builds, and runs the docs page's walkthrough against the production ad server with a `{publisher}-dev` token.
2. Tell the publishers waiting for the release; the changelog entry is the release note.

## Before the first App Store submission that includes the SDK

* `PrivacyInfo.xcprivacy` declares what the SDK collects and the required-reason APIs it uses. It mirrors
  `sdk-swift`; have legal confirm `NSPrivacyTracking` and the data types before a publisher ships.
* An app that lets the SDK show the ATT dialog (`requestTrackingAuthorization: true`) needs
  `NSUserTrackingUsageDescription` in its Info.plist.
