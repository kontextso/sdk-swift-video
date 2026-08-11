# Kontext Swift Video SDK

Swift SDK for integrating Kontext video ads into short-drama and other video-first iOS apps.

> **Status: early development.** The SDK itself is not published yet. This repository currently contains an example short-drama app that will be used as the integration playground for the SDK.

## Example app

`Example/` contains a minimal short-drama app:

- **Home screen** — a grid of story cards.
- **Player** — tapping a story opens a fullscreen vertical video feed; swipe up/down to move between episodes, tap to play/pause.

The videos are public sample clips (Google's `gtv-videos-bucket`) used purely for testing.

### Requirements

- Xcode 16+
- iOS 17.0+ (simulator or device)

### Running

```bash
cd Example
open Example.xcodeproj
```

Then run the `Example` scheme.

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `Example/project.yml`. If you change the project structure, regenerate it:

```bash
cd Example
xcodegen generate
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
