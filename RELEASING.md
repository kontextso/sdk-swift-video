# Releasing

How to cut a release of the **Kontext Video SDK**. Replace `0.1.0` with the version at hand.

> Versions are `MAJOR.MINOR.PATCH`, digits only, no `v` prefix, no leading zeros, no prerelease suffix:
> `0.1.0`, never `v0.1.0`, `0.01.0` or `0.2.0-rc1`. While the SDK is pre-1.0, a breaking change bumps the
> minor version (`0.2.0`); after 1.0 it bumps the major. The SDK ships through Swift Package Manager only:
> CocoaPods trunk stops accepting new versions on December 2, 2026.

## 1. Check main

1. Checkout `main` and pull.
2. Build the SDK and run the tests (commands in [DEVELOPMENT.md](DEVELOPMENT.md)).
3. Run the example on a device against the ad server: open each of the five videos and watch its ad from
   start to end. The status line under the title must show the impression, then the one `didEnd`.

## 2. Update the changelog

Add a `## 0.2.0` heading at the top of `CHANGELOG.md` with what changed since the last release. Breaking
changes get a `### Breaking` section first, with what integrators must do; then `### Added`, `### Changed`
and `### Fixed`, each left out when empty.

```markdown
## 0.2.0
### Breaking
* What changed and what integrators need to do.
### Added
* …
### Changed
* …
### Fixed
* …
```

## 3. Bump the version

One place: `SDKInfo.version` in `Sources/KontextVideoSDK/Payloads/SDKInfo.swift`. The SDK sends it with every request,
and CI refuses a release tag that does not match it. The docs page's
`upToNextMinor(from: "0.1.0")` means "0.1.x, the patches only"; while the SDK is pre-1.0 a minor version may
break, so the docs move to the new minor when it ships, after its notes are written.

```
Sources/KontextVideoSDK/Payloads/SDKInfo.swift    static let version = "0.1.0"
```

## 4. Commit and tag

```bash
git add CHANGELOG.md Sources/KontextVideoSDK/Payloads/SDKInfo.swift
git commit -m "Release 0.1.0"
git tag -a 0.1.0 -m "Release 0.1.0"
git push origin main 0.1.0
```

The tag is what SPM resolves; publishers pin to it with `from:` or `exact:`. The push of the tag runs the
`release-tag` CI job, which fails if the tag and `SDKInfo.version` differ or `CHANGELOG.md` has no `## 0.1.0`
section. It runs after the tag exists, so a failure means the tag is already public: delete it, fix the version
or the changelog, and cut it again, before anyone resolves it.

```bash
git push --delete origin 0.1.0 && git tag -d 0.1.0
# fix SDKInfo.version, commit, then tag and push as above
```

## 5. Publish the GitHub release

The tag alone is what SPM needs, but the repository's Releases page is where integrators look for the notes.
Create the release from the tag, with the changelog section as its body:

```bash
gh release create 0.1.0 --title 0.1.0 --notes-file <(awk '/^## 0.1.0$/{f=1;next} /^## /{f=0} f' CHANGELOG.md)
```

## 6. Verify

1. The tag push also runs the **Release consumer** workflow: `Extras/ReleaseCheck` resolves
   `.package(url: "https://github.com/kontextso/sdk-swift-video.git", exact: "0.1.0")` from GitHub and builds
   with Xcode 16.0. It must be green; rerun it by hand (Actions → Release consumer → Run workflow) with the tag.
2. A fresh app with that dependency runs the docs page's walkthrough against the production ad server with a
   `{publisher}-dev` token.
3. Tell the publishers waiting for the release; the changelog entry is the release note.

## Before the first App Store submission that includes the SDK

* `PrivacyInfo.xcprivacy` declares what the SDK collects and the required-reason APIs it uses. It declares
  no tracking (`NSPrivacyTracking` false); publishers check their App Store privacy labels against it.
* An app that lets the SDK show the ATT dialog (`requestTrackingAuthorization: true`) needs
  `NSUserTrackingUsageDescription` in its Info.plist.
