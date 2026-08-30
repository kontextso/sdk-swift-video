// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KontextVideoSDK",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "KontextVideoSDK",
            targets: ["KontextVideoSDK"]
        )
    ],
    dependencies: [
        // Pre-1.0 KontextKit: pin exact, matching sdk-swift and the podspec so SPM and
        // CocoaPods consumers resolve the same version. Switch to from: "1.0.0" at 1.0.
        .package(url: "https://github.com/kontextso/kontextkit-ios.git", exact: "0.1.0"),
    ],
    targets: [
        .target(
            name: "KontextVideoSDK",
            dependencies: [
                .product(name: "KontextKit", package: "kontextkit-ios"),
            ],
            path: "Sources/KontextVideoSDK",
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
