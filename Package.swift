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
    targets: [
        .target(
            name: "KontextVideoSDK",
            path: "Sources/KontextVideoSDK",
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "KontextVideoSDKTests",
            dependencies: ["KontextVideoSDK"],
            path: "Tests/KontextVideoSDKTests"
        )
    ]
)
