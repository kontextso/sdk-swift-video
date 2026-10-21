# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

Kontext Video SDK for iOS: overlay, pause and linear ads in video-first apps. Swift 5.9, iOS 14+, Swift Package
Manager only (CocoaPods trunk is read-only from December 2026). The contract is the Notion document *Video Ads API & SDK v2* and its subpage
*Video Ads SDK Public API*; the public API is frozen for manual-mode v1. Timed mode (windows, `nextRequestAt`, the playhead clock)
is specified on the Notion pages but deliberately not in the SDK yet; the wire's timed-mode fields decode and are ignored.

## Commands

```bash
xcodebuild build -scheme KontextVideoSDK -destination 'generic/platform=iOS Simulator'
xcodebuild test  -scheme KontextVideoSDK -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17 Pro'
```

The example (`Example/`, XcodeGen) talks to the mock server `sdk-video-mock-server` on `localhost:5175`;
`--demo` runs every flow hands-free. See [DEVELOPMENT.md](DEVELOPMENT.md).

## Rules

- Commit directly to `main`; no feature branches.
- Follow ad-SDK conventions (AdMob, AppLovin MAX, IMA) and modern Apple patterns: `async throws` for one-result
  calls, a delegate for lifetime events, nested model types under `KontextVideo`, `TimeInterval` seconds in the
  public API (milliseconds on the wire).
- The lifecycle guarantee is sacred: after a successful `show`, exactly one `didEnd`. `VideoAd.end(_:)` is the
  only terminal path.
- The page never fires a beacon; `Tracker` does, each entry once.
- Public API changes go to the Notion page first.
- Facts about the device, consent and attribution come from KontextKit; what the SDK needs and KontextKit lacks goes into KontextKit, not into a workaround here.
