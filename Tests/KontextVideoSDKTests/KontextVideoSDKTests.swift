import XCTest
@testable import KontextVideoSDK

final class KontextVideoSDKTests: XCTestCase {
    @MainActor
    func testCreateSessionUsesAllFormatsByDefault() {
        let session = KontextVideo.createSession(VideoSessionOptions(
            publisherToken: "pub-test",
            userId: "user-1"
        ))
        XCTAssertEqual(session.options.enabledFormats, VideoAdFormat.allCases)
    }

    @MainActor
    func testStartVideoReturnsHandleForThatVideo() {
        let session = KontextVideo.createSession(VideoSessionOptions(
            publisherToken: "pub-test",
            userId: "user-1"
        ))
        let ads = session.startVideo(externalId: "ep-1042")
        XCTAssertEqual(ads.externalId, "ep-1042")
    }

    func testInstallIDIsStableAcrossReads() {
        XCTAssertEqual(InstallID.current, InstallID.current)
        XCTAssertFalse(InstallID.current.isEmpty)
    }
}
