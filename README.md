# Kontext Swift Video SDK

A Swift SDK for integrating Kontext video ads (overlay, pause and linear) into short-drama and other video-first iOS apps.

📚 Full documentation: [Kontext Swift Video SDK](https://docs.kontext.so/video/sdk/swift)

## Good to know

A custom player passed to `VideoAds.track(_:)` is held strongly. If it references the `VideoAds` (or the object that owns it, such as your player model), the two keep each other alive until `destroy()`: call `destroy()` when the viewer leaves the video, or don't reference the ads from the adapter.
