# Events

Every ad lifecycle event is delivered through the `onEvent` closure you pass
in `VideoSessionOptions`, always on the **main thread**:

```swift
let session = KontextVideo.createSession(VideoSessionOptions(
    publisherToken: "pub-…",
    userId: "user-123",
    onEvent: { event in
        switch event {
        case .loaded(let d):
            for r in d.results { print("loaded:", r.format, r.ads.count, r.noFillReason ?? "") }
        case .shown(let d):     analytics.log("ad_shown", d.adId)
        case .clicked(let d):   analytics.log("ad_clicked", d.adId)
        case .closed(let d):    break
        case .completed(let d): break
        case .error(let e):     log.error(e.message)
        }
    }
))
```

Events are informational — the SDK never requires you to react to one
(show/hide/load are separate, explicit calls). Identifiers:

- `videoId` — the id you passed to `setVideo(id:)`.
- `adId` — unique per **served ad**. Two `shown` events with different
  `adId`s are two different ads; the same creative can appear behind many
  served ads.

## The events

### `.loaded(LoadedData)`

A `load(formats:)` finished: the server answered, and this is what is
ready. **Exactly one per `load` call**, with one result row per requested
format (mirrors Google's single load completion rather than MAX's
didLoad/didFailToLoad pair).

| Field | Type | Meaning |
|---|---|---|
| `videoId` | `String` | Your video id |
| `results` | `[FormatResult]` | One row per requested format |

`FormatResult`:

| Field | Type | Meaning |
|---|---|---|
| `format` | `VideoAdFormat` | `.pause`, `.swipe`, or `.overlay` |
| `ads` | `[Ad]` | The served ads, in order — each carries its `id` (matching the `adId` on later `shown`/`clicked` events). Empty = no fill |
| `noFillReason` | `String?` | Why the server served less than it could have (`no_ad_match`, `frequency_capped`, `content_unsafe`, …) |

Examples, as JSON:

```jsonc
// everything filled
{ "videoId": "100001-6", "results": [
  { "format": "pause",   "ads": [{ "id": "bid-p1" }] },
  { "format": "swipe",   "ads": [{ "id": "bid-s1" }] },
  { "format": "overlay", "ads": [{ "id": "bid-o1" }, { "id": "bid-o2" }, { "id": "bid-o3" }] }
] }

// only the pause ad filled
{ "videoId": "100001-6", "results": [
  { "format": "pause",   "ads": [{ "id": "bid-p1" }] },
  { "format": "swipe",   "ads": [], "noFillReason": "frequency_capped" },
  { "format": "overlay", "ads": [], "noFillReason": "no_ad_match" }
] }

// nothing filled (whole request refused)
{ "videoId": "100001-6", "results": [
  { "format": "pause",   "ads": [], "noFillReason": "content_unsafe" },
  { "format": "swipe",   "ads": [], "noFillReason": "content_unsafe" },
  { "format": "overlay", "ads": [], "noFillReason": "content_unsafe" }
] }
```

A non-empty `ads` with a `noFillReason` means the server could have
served more (e.g. an overlay window stayed empty). Not emitted when the
request itself failed — that's `.error`.

### `.shown(AdData)`

The ad is on screen — emitted when the view is mounted (for the swipe ad,
when playback is about to start). The SDK separately fires the
`impression` + `creative_view` tracking when the creative has actually
rendered (image painted / first video frame), so `shown` may precede the
tracked impression by the image-load time.

### `.clicked(AdData)`

The user tapped the ad. The SDK opens the click-through
(`/impression/{bid}/redirect`, which records the click server-side) in the
in-app browser — you don't need to do anything.

### `.closed(AdData)`

The user dismissed the ad **from inside it**: the swipe ad's Skip button,
or your call to `swipe.hide()` after the user swiped it away. The ad is
already hidden and `skip`/`close` tracking has fired. For the swipe ad,
`onFinished` also runs (Skip counts as finishing). Your own `pause.hide()` /
`overlay.hide()` calls do **not** emit `.closed` — you initiated those.

### `.completed(AdData)`

A video ad (swipe) played to the end. Already hidden; `video.complete`
tracking fired; `onFinished` runs.

### `.error(ErrorData)`

Something failed: the `/instream/preload` request (network, non-200,
undecodable body) or unplayable ad media. No `.loaded` accompanies a
failed request — `.loaded` means "the server answered".

| Field | Type | Meaning |
|---|---|---|
| `videoId` | `String?` | The video the failure belongs to, when known |
| `message` | `String` | Diagnostic description |

For a swipe ad whose media fails after `show`, the SDK also calls
`onFinished` so your flow continues.

## Per-format cheat sheet

| | `.pause` | `.swipe` | `.overlay` |
|---|---|---|---|
| `loaded` result row | 0–1 ad | 0–1 ad | 0–N ads |
| `shown` | on `show(in:)` | on `show(in:…)` | on `show(in:)` (windowed or manual) |
| `clicked` | tap | tap on video | tap |
| `closed` | – | Skip button / your `hide()` after a user swipe | – |
| `completed` | – | video end | – |
