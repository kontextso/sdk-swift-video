// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KontextVideoSDK",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "KontextVideoSDK", targets: ["KontextVideoSDK"]),
    ],
    targets: [
        .target(name: "KontextVideoSDK", path: "Sources/KontextVideoSDK"),
    ]
)
