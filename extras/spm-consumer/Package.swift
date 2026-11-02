// swift-tools-version: 5.9
import PackageDescription

// A publisher's package, outside the SDK's own: it gets the SDK as a publisher does, by git URL and an exact
// release tag, so it builds only once that tag is pushed. The release-consumer workflow sets the version below
// to the tag it builds; locally, edit it and run
// `xcodebuild build -scheme SPMConsumer -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`.
let package = Package(
    name: "SPMConsumer",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "SPMConsumer", targets: ["SPMConsumer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kontextso/sdk-swift-video.git", exact: "0.2.0"),
    ],
    targets: [
        .target(
            name: "SPMConsumer",
            dependencies: [
                .product(name: "KontextVideoSDK", package: "sdk-swift-video"),
            ]
        ),
    ]
)
