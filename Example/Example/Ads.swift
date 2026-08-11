import KontextVideoSDK

enum Ads {
    @MainActor static let session = KontextVideo.createSession(VideoSessionOptions(
        publisherToken: "test-publisher-token",
        userId: "example-user",
        onEvent: { event in
            print("[KontextVideoSDK] \(event)")
        }
    ))
}
