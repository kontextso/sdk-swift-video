// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KontextVideoSDK",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "KontextVideoSDK", targets: ["KontextVideoSDK"]),
    ],
    dependencies: [
        // Pre-1.0 KontextKit: pin exact, the same version sdk-swift uses.
        .package(url: "https://github.com/kontextso/kontextkit-ios.git", exact: "0.2.0"),
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
        .testTarget(
            name: "KontextVideoSDKTests",
            dependencies: ["KontextVideoSDK"],
            path: "Tests/KontextVideoSDKTests"
        ),
    ]
)
