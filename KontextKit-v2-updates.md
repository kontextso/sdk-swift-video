# KontextKit v2 updates

Changes to make in [kontextkit-ios](https://github.com/kontextso/kontextkit-ios) for its next release, collected while
building this SDK against KontextKit 0.1.0. Each note says what we do in the meantime, so the workaround can be removed
once KontextKit ships it.

## 1. AdAttributionKit identifiers

`SKAdNetworkIdsProvider.collect()` reads the SKAdNetwork ids from `SKAdNetworkItems` in the app's `Info.plist`.
AdAttributionKit has its own key, `AdNetworkIdentifiers`, a plain array of strings, and the v2 API reports both lists
(`attribution: { skan, aak }` on `/init`).

Add an `AdAttributionKitIdsProvider` (or a second method on the SKAN provider) that returns `AdNetworkIdentifiers`,
an empty array when the key is missing or malformed, like the SKAN one.

Meanwhile: `AttributionIds.current()` in `Sources/KontextVideoSDK/API/DeviceInfo.swift` reads the key itself.

## 2. OS name on iPad

`OSInfoProvider.collect()` always reports `name: "ios"`. The v2 API distinguishes `ios`, `ipados` and `tvos`.

Report `ipados` when `UIDevice.current.userInterfaceIdiom == .pad`, and `tvos` on tvOS once KontextKit builds for it.

Meanwhile: `OSInfo.current()` in `DeviceInfo.swift` overrides the name from the idiom.

## 3. Hardware type vocabulary

`HardwareInfoProvider.collect()` reports `type` as `handset`, `tablet` or `other`. The v2 API uses the OpenRTB-derived
set `phone`, `tablet`, `tv`, `settopbox`, `desktop`, `other`.

Rename `handset` to `phone` (or add a typed enum with the v2 set) and report `tv` on tvOS.

Meanwhile: `HardwareInfo.current()` in `DeviceInfo.swift` maps the strings.

## 4. Screen size in points

`ScreenInfoProvider.collect()` reports `width` and `height` in physical pixels. The v2 API wants logical pixels
(points on iOS) plus `dpr`; the server multiplies where OpenRTB needs physical pixels.

Report points (`UIScreen.main.bounds`) and keep `dpr`, or add `pointWidth` and `pointHeight` next to the pixel values.

Meanwhile: `AdsDevice.current()` in `Sources/KontextVideoSDK/API/AdsRequest.swift` divides by `dpr`.

## 5. Consent beyond TCF

`TCFDataProvider.getTCFData()` reads only the TCF keys (`IABTCF_TCString`, `IABTCF_gdprApplies`). The v2 API also
carries the Global Privacy Platform string and sections (`IABGPP_HDR_GppString`, `IABGPP_GppSID`, written as `2_7` or
`2,7`) and the legacy US Privacy string (`IABUSPrivacy_String`), and both SDKs want the same tolerant parsing of
`gdprApplies` (number, boolean or string; only 0 and 1 count) for every key.

Add the three keys to the provider (a `ConsentData` with `gpp`, `gppSid`, `usPrivacy` next to the TCF fields), keeping
the reading in one place; the merge with the publisher's own values stays in each SDK (the CMP wins, the publisher
fills what it did not write).

Meanwhile: `ConsentStorage.read` in `Sources/KontextVideoSDK/API/Privacy.swift` reads all five keys itself.

## 6. Open Measurement as a separate product

Every consumer of `KontextKit` links `OMSDK_Kontextso.xcframework` (2.3 MB) and takes on the IAB OM licence, because
the one target depends on the binary. The video SDK uses nine providers and nothing from `Sources/OMSDK/`; nothing
outside that folder references OM either, so the split is clean.

Make it two targets and two products: `KontextKit` (`Sources/KontextKit/`: DeviceInfo, Privacy, StoreKit, UI,
Utilities, `PrivacyInfo.xcprivacy`) and `KontextKitOM` (`Sources/KontextKitOM/`: the OM sources and `omsdk-v1.js`,
depending on `KontextKit` and the binary target). CocoaPods: subspecs `KontextKit/Core` (the default) and
`KontextKit/OMSDK` (`vendored_frameworks`, `preserve_paths` for `OMLICENSE`). sdk-swift depends on both and writes
`import KontextKitOM` where it uses `OMManager`; sdk-swift-video depends on `KontextKit` only, and adds the OM product
on the day it implements Open Measurement (Google IMA Notes, decision 6).

Done: KontextKit 0.2.0 (kontextso/kontextkit-ios#6), this SDK pins it, kontextso/sdk-swift#131 takes both products.
