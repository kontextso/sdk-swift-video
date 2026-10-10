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
            ]
        ),
    ]
)
