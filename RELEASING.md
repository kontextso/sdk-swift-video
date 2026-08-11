# Releasing

- This document describes the process for cutting a new release of the **Kontext SDK**.  
- Follow these steps to ensure consistency across releases.
- Replace version `1.0.0` with the proper one instead.

> We use versioning without `v` at the front to align it for both SPM and Cocoapods so please keep that in mind.
> For Example: `1.0.0`.

---

## 1. Create a release branch and test

1. Checkout branch `main`
2. Pull the latest changes
3. Create a new branch `release/1.0.0`
4. Make sure it builds.
5. Run tests and make sure they are green.
6. Run Example and make sure it's OK.

## 2. Update the changelog

Edit `CHANGELOG.md` to include the new release notes at the top.

Standard release:
```markdown
## 1.0.0
* Add new feature.
* Fix some bug.
* Remove old feature.
```

If the release contains breaking changes, add a `### Breaking` section before the bullet points:
```markdown
## 2.0.0
### Breaking
Short description of what changed and what integrators need to do.

* Add new feature.
* Fix some bug.
```


## 3. Update the CocoaPods spec

Update the version in KontextVideoSDK.podspec:

```
s.version = "1.0.0"

```

## 4. Update SDKInfo

Update the version in SDKInfo.swift to match the new version:


```swift

struct SDKInfo {
    ...
    static let sdkVersion = "1.0.0"
    ...
}
```

## 5. Commit changes

Commit the changed files to `release/1.0.0` branch:

```bash
git add CHANGELOG.md KontextVideoSDK.podspec Sources/KontextVideoSDK/SDKInfo.swift
git commit -m "Prepare release 1.0.0"
```

## 6. Open pull request

1. Create a PR to `main` named: "Release version 1.0.0" and use the last changelog entry as the PR description.
2. Merge the PR to `main`.

## 7. Create an annotated tag

```bash
git checkout main
git pull
git tag -a 1.0.0 -m "Release 1.0.0"
git push origin 1.0.0
```

## 8. Publish to CocoaPods trunk

```bash
pod trunk push KontextVideoSDK.podspec --allow-warnings
```

## 9. Verify

1. Check that the version is available on the [CocoaPods page](https://cocoapods.org/pods/KontextVideoSDK).
2. Integrate the new version into the internal testing app and confirm it builds and runs.
3. Release the internal testing app with updated SDK version.
