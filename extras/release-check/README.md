# Release check

A small package that uses the SDK the way a publisher's app does: it gets `KontextVideoSDK` by git URL at an
exact release tag (`.package(url: "https://github.com/kontextso/sdk-swift-video.git", exact: "X.Y.Z")`), not
from this repo's source, and builds it for a device. It catches what the SDK's own build cannot see: a file left
out of the tag, a dependency that does not resolve from GitHub, or a public API the integration guide uses that
the release lost or renamed.

It is never shipped or run: `Sources/ReleaseCheck/Integration.swift` only has to compile.

## When it runs

- **On a tag push** (`release-consumer.yml`): against that tag, with Xcode 16.0 (the oldest supported).
- **By hand** (Actions → Release consumer → Run workflow, with a tag already pushed).
- Never on `main` or pull requests: before the tag is on GitHub there is nothing to resolve.

## Run it locally

Set the version in `Package.swift` (`exact: "X.Y.Z"`) to a pushed tag, then:

```bash
cd extras/release-check
xcodebuild build -scheme ReleaseCheck -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```
