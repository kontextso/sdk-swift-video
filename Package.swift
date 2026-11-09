// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KontextVideoSDK",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "KontextVideoSDK", targets: ["KontextVideoSDK"]),
        // Optional: `ads.track(ttVideoEngine:)` for an app playing with TTSDK (read through Objective-C, no TTSDK dependency).
        .library(name: "KontextVideoTTSDK", targets: ["KontextVideoTTSDK"]),
    ],
    dependencies: [
        // Pre-1.0 KontextKit: patches (0.6.x) are taken, a minor release may break and needs an SDK release.
        .package(url: "https://github.com/kontextso/kontextkit-ios.git", .upToNextMinor(from: "0.6.0")),
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
                // Swift 6's isolation and Sendable checking, as warnings: what a publisher building in
                // Swift 6 language mode would see as errors.
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "KontextVideoTTSDK",
            dependencies: ["KontextVideoSDK"],
            path: "Sources/KontextVideoTTSDK",
            exclude: ["README.md"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "KontextVideoSDKTests",
            dependencies: ["KontextVideoSDK", "KontextVideoTTSDK"],
            path: "Tests/KontextVideoSDKTests",
            resources: [
                // The shared malformed-answer corpus, a copy of the video-sdk-corpus repo (its sync.sh writes it).
                .copy("Corpus"),
            ]
        ),
    ]
)
