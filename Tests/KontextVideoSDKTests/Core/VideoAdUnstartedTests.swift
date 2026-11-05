import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// A video ad that ends on screen before its first frame (`video.start`): no impression, and one outcome for
/// the server. The video cannot start: the page's `ad.error`, so `error`. The app, the viewer or an
/// interruption ends it first: `close`, whatever `didEnd` says.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdUnstartedTests {
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

    /// A full-screen video pause ad: a video creative shown inline.
    private func videoPause(_ id: String) -> [String: Any] {
        Fixtures.ad(id: id, creative: "video", position: "fullscreen", size: nil)
    }

    /// `show(from:)` plus what UIKit's presentation completion does; the runner never completes a transition.
    private func presentLinear(_ ad: VideoAd) throws {
        try ad.show(from: window.root)
        ad.linearController?.loadViewIfNeeded()
        window.add(ad.bridge.webView)
        ad.presented()
    }

    /// The events the server received for `adId`, after the beacons in flight arrived.
    private func events(_ adId: String) async -> [String] {
        await sleepMs(80)
        return harness.server.beacons.filter { $0.adId == adId }.map { $0.event }
    }

    @Test func aVideoThatCannotStartFailsWithTheErrorBeaconAndNoClose() async throws {
        let (ad, delegate, _) = try await makeAd(videoPause("u1"))
        try ad.show(in: harness.player.view)
        // The page's start timeout: autoplay never began and nobody tapped, or the video stalled.
        send(ad, "ad.error", ["code": 405])
        #expect(delegate.events.suffix(2) == ["fail", "end:failed"])
        let fired = await events("u1")
        #expect(fired.contains("error"))
        #expect(harness.server.beacons.first { $0.adId == "u1" && $0.event == "error" }?.query["code"] == "405")
        #expect(!fired.contains("close") && !fired.contains("impression"), "error is the outcome; a close would be a second one")
    }

    @Test func aVideoAdDismissedBeforeItsFirstFrameFiresClose() async throws {
        let (ad, delegate, _) = try await makeAd(videoPause("u2"))
        try ad.show(in: harness.player.view)
        try ad.dismiss()
        #expect(delegate.endReasons == [.dismissed], "the reason stays the app's")
        let fired = await events("u2")
        #expect(fired.filter { $0 == "close" }.count == 1)
        #expect(fired.contains("creativeView") && fired.contains("overlayViewDuration"))
        #expect(!fired.contains("impression") && !fired.contains("error"))
        #expect(!fired.contains { ["viewable", "notViewable", "viewUndetermined"].contains($0) }, "no verdict without an impression: \(fired)")
    }

    @Test func aLinearAdDestroyedBeforeItsFirstFrameFiresClose() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.linearAd(id: "u3"))
        try presentLinear(ad)
        ads.destroy()
        #expect(await waitUntil { delegate.endReasons == [.destroyed] })
        let fired = await events("u3")
        #expect(fired.filter { $0 == "close" }.count == 1)
        #expect(!fired.contains("impression") && !fired.contains("error"))
    }

    @Test func thePagesCloseBeforeTheFirstFrameFiresOneClose() async throws {
        let (ad, delegate, _) = try await makeAd(videoPause("u4"))
        try ad.show(in: harness.player.view)
        send(ad, "ad.close", ["reason": "close"])
        #expect(delegate.endReasons == [.closed])
        let fired = await events("u4")
        #expect(fired.filter { $0 == "close" }.count == 1, "the page's close and the outcome are one beacon")
    }

    @Test func aVideoThatStartedFiresNoCloseWhenTheAppEndsIt() async throws {
        let (ad, delegate, _) = try await makeAd(videoPause("u5"))
        try ad.show(in: harness.player.view)
        send(ad, "video.start", ["playhead": 0])
        try ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
        let fired = await events("u5")
        #expect(fired.contains("impression") && !fired.contains("close"))
    }

    @Test func aLinearAdDestroyedBeforeUIKitPresentedItFiresNothing() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.linearAd(id: "u6"))
        try ad.show(from: window.root)
        ads.destroy()
        #expect(await waitUntil { delegate.endReasons == [.destroyed] })
        let fired = await events("u6")
        #expect(!fired.contains("creativeView") && !fired.contains("close"), "never on screen: nothing to close")
    }
}
}
