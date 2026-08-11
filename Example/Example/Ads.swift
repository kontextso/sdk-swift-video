import Foundation
import KontextVideoSDK

enum Ads {
    /// Develop-environment publisher token (same one VideoNexus uses).
    /// Move to a gitignored secrets file before the repo goes public.
    private static let publisherToken = "kontexttv-dev"

    /// "Mike" — a persona user id from the video-ad-formats user profiles;
    /// known to the develop ad server, so ad copy gets personalized.
    private static let userId = "cf473175-d591-469e-a7cc-73fd538bad9b"

    /// The current /ads endpoint has no external-id resolution yet, so the
    /// example requests ads for a real analyzed title on the develop server:
    /// "Agent Kim Reactivated - S01E01".
    static let demoTitleId = "019f5e4b-af9b-7697-a9b8-db28d6752407"

    @MainActor static let session = KontextVideo.createSession(VideoSessionOptions(
        publisherToken: publisherToken,
        userId: userId,
        adServerURL: URL(string: "https://server.develop.megabrain.co")!,
        adsSource: .mock,  // change to .server for real ads (use demoTitleId as externalId)
        onEvent: { event in
            print("[Example] event: \(event)")
        }
    ))
}
