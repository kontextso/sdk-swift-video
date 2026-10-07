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

Meanwhile: `AttributionIds.current()` in `Sources/KontextVideoSDK/Networking/DeviceInfo.swift` reads the key itself.

## 2. OS name on iPad

`OSInfoProvider.collect()` always reports `name: "ios"`. The v2 API distinguishes `ios`, `ipados` and `tvos`.

Report `ipados` when `UIDevice.current.userInterfaceIdiom == .pad`, and `tvos` on tvOS once KontextKit builds for it.

Meanwhile: `OSInfo.current()` in `DeviceInfo.swift` overrides the name from the idiom.

## 3. Hardware type vocabulary

`HardwareInfoProvider.collect()` reports `type` as `handset`, `tablet` or `other`. The v2 API uses the OpenRTB-derived
set `phone`, `tablet`, `tv`, `settopbox`, `desktop`, `other`.

Rename `handset` to `phone` (or add a typed enum with the v2 set) and report `tv` on tvOS.

Meanwhile: `HardwareInfo.current()` in `DeviceInfo.swift` maps the strings.
