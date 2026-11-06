import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// A click on the ad: the beacon, the click-through with the same fire id, the fallback, the refused schemes,
/// and which entries an area fires. The page is driven through the bridge, as in VideoAdTests.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdClickTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    /// Keeps every `VideoAds` a test created alive for the test's duration: the ad holds its owner weakly.
    private let owners = Owners()

    final class Owners {
        var all: [VideoAds] = []
    }

    init() {
        harness.player.view.frame.origin.y = 120
        window.add(harness.player.view)
    }

    /// A loaded ad, owned by a new `VideoAds`, with a recording delegate.
    private func makeAd(_ payload: [String: Any]) async throws -> (VideoAd, RecordingDelegate, VideoAds) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        send(ad, "ad.loaded")
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        return (ad, delegate, ads)
    }

    private func send(_ ad: VideoAd, _ type: String, _ extra: [String: Any] = [:]) {
        var body: [String: Any] = ["adId": ad.id, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        ad.bridge.receive(body, from: sender)
    }

    /// `show(from:)` plus what UIKit's presentation completion does; the runner never completes a transition.
    private func presentLinear(_ ad: VideoAd) throws {
        try ad.show(from: window.root)
        ad.linearController?.loadViewIfNeeded()
        window.add(ad.bridge.webView)
        ad.reachedScreen()
    }

    /// Every beacon the server received, `event(part)` for a part's.
    private func beacons() async -> [String] {
        await beaconsSettled()
        return harness.server.beacons.map { beacon in beacon.query["part"].map { "\(beacon.event)(\($0))" } ?? beacon.event }
    }

    @Test func aClickThroughWithTheFireIdMacroOpensWithTheClickBeaconsFireId() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p14b"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://ads.test/redirect?fid=[KONTEXT_FIREID]&cb=[CACHEBUSTING]"])
        _ = await beacons()
        let click = try #require(harness.server.beacons.first { $0.event == "click" })
        let fid = try #require(click.query["fid"])
        #expect(opened.count == 1 && opened[0].query?.contains("fid=\(fid)") == true, "one occurrence, the redirect and the beacon: \(opened)")
        #expect(opened[0].absoluteString.contains("[") == false && opened[0].absoluteString.contains("%25") == false, "macros filled, nothing re-encoded")
    }

    @Test func clickOpensTheURLFiresClickAndTellsTheDelegate() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p14"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://brand.test/offer", "area": "cta"])
        #expect(delegate.clicks == [VideoAd.Click(area: .other("cta"))], "where the viewer tapped; the URL is the SDK's to open")
        #expect(opened.map(\.absoluteString) == ["https://brand.test/offer"])
        #expect(await harness.beaconArrives("click"))
        #expect(ad.hasEnded == false, "a click does not end the ad")
    }

    @Test func aRefusedClickOpensItsWebFallbackInstead() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p15b"))
        var opened: [String] = []
        Environment.openURL = { url, completion in opened.append(url.absoluteString); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "tel:+15555550100", "fallbackUrl": "https://brand.test/offer"])
        #expect(opened == ["https://brand.test/offer"], "a call is never placed from an ad")
        #expect(delegate.clicks.count == 1)
        let fired = await beacons()
        #expect(fired.contains("click"))
    }

    @Test func endCardClickUsesTheEndCardsEntry() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i6"))
        Environment.openURL = { _, completion in completion(true) }
        try presentLinear(ad)
        send(ad, "video.start", ["playhead": 0])
        send(ad, "video.complete", ["playhead": 10_000])
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://brand.test", "area": "endCard"])
        let fired = await beacons()
        #expect(fired.contains("click(endCard)"))
        #expect(!fired.contains("click"), "the creative's own click entry stays unfired")
    }

    @Test func anEndCardClickOnAnAdWithoutEndCardEntriesIsTheCreativesClick() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p16e"))
        Environment.openURL = { _, completion in completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://brand.test", "area": "endCard"])
        #expect(await harness.beaconArrives("click"), "every accepted click is counted")
    }
}
}
