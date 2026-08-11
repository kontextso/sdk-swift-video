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

    func testVMAPParserReadsAdBreaks() throws {
        // Trimmed capture of a real /instream/vmap response.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <vmap:VMAP xmlns:vmap="http://www.iab.net/videosuite/vmap" version="1.0">
        <vmap:AdBreak breakType="nonlinear" breakId="slot-0" timeOffset="00:20:18.401">
        <vmap:AdSource id="0" allowMultipleAds="false" followRedirects="false">
        <vmap:VASTAdData><VAST version="4.2" xmlns="http://www.iab.com/VAST"><Ad id="slot-0"><InLine>
        <Creatives><Creative id="slot-0-creative"><CreativeExtensions>
        <CreativeExtension type="kontext-overlay">
        <kontext:Overlay xmlns:kontext="urn:kontext:vast-ext:1.0" sessionId="69f23ae7-591c-41aa-81e3-d077c53bfe4e" index="0" position="bottom" endMs="1283951">
        <kontext:AdJson><![CDATA[https://server.develop.megabrain.co/api/frame/019ff0a3-d9ac-711e-b755-e7378fb07f71?format=json]]></kontext:AdJson>
        </kontext:Overlay></CreativeExtension></CreativeExtensions>
        <NonLinearAds><NonLinear width="390" height="152" minSuggestedDuration="00:01:05.550" scalable="false">
        <IFrameResource><![CDATA[https://server.develop.megabrain.co/api/frame/019ff0a3-d9ac-711e-b755-e7378fb07f71]]></IFrameResource>
        </NonLinear></NonLinearAds></Creative></Creatives></InLine></Ad></VAST></vmap:VASTAdData>
        </vmap:AdSource></vmap:AdBreak></vmap:VMAP>
        """
        let ads = VMAPParser.parse(Data(xml.utf8))
        XCTAssertEqual(ads.count, 1)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ad.index, 0)
        XCTAssertEqual(ad.startMs, 1_218_401)
        XCTAssertEqual(ad.endMs, 1_283_951)
        XCTAssertEqual(ad.position, "bottom")
        XCTAssertEqual(ad.bidId, "019ff0a3-d9ac-711e-b755-e7378fb07f71")
        XCTAssertEqual(ad.width, 390)
        XCTAssertEqual(ad.sessionId, "69f23ae7-591c-41aa-81e3-d077c53bfe4e")
    }

    func testTimeOffsetParsing() {
        XCTAssertEqual(VMAPParser.milliseconds(fromTimeOffset: "00:20:18.401"), 1_218_401)
        XCTAssertEqual(VMAPParser.milliseconds(fromTimeOffset: "01:00:00.000"), 3_600_000)
        XCTAssertNil(VMAPParser.milliseconds(fromTimeOffset: "banana"))
    }
}
