import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The beacons an ad's end fires when it was on screen without an impression, per end reason: a video ad
/// before its first frame, and an image ad ended while it was being presented, before its impression.
///
/// ```
///   end reason                                    video ad, no impression      image ad, no impression
///   dismissed, destroyed, interrupted, completed  close                        nothing
///   skipped, closed, resumed                      nothing (their own beacon)   nothing
///   failed                                        nothing (`error` fired)      nothing
/// ```
///
/// An inline ad that reached the screen also fires `overlayViewDuration` at every end.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdEndBeaconTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    private let owners = Owners()

    private static let reasons: [VideoAd.EndReason] = [.completed, .skipped, .closed, .resumed, .failed, .interrupted, .dismissed, .destroyed]

    init() {
        harness.player.view.frame.origin.y = 120
        window.add(harness.player.view)
    }

    private func makeAd(_ payload: [String: Any]) async throws -> (VideoAd, RecordingDelegate) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        send(ad, "ad.loaded")
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        return (ad, delegate)
    }

    private func send(_ ad: VideoAd, _ type: String, _ extra: [String: Any] = [:]) {
        var body: [String: Any] = ["bidId": ad.id, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        ad.bridge.receive(body, from: sender)
    }

    /// The events the server received for `bidId`, once `last` arrived and the beacons still in flight did.
    private func events(_ bidId: String, after last: String) async -> [String] {
        _ = await waitUntil { harness.server.beacons.contains { $0.bidId == bidId && $0.event == last } }
        await beaconsSettled()
        return harness.server.beacons.filter { $0.bidId == bidId }.map { $0.event }
    }

    @Test func aVideoAdEndedBeforeItsFirstFrame() async throws {
        for reason in Self.reasons {
            let id = "ev-\(reason)"
            let (ad, delegate) = try await makeAd(Fixtures.pauseFullscreenAd(id: id, creative: "video"))
            try ad.show(in: harness.player.view)
            ad.end(reason)
            #expect(delegate.endReasons == [reason])
            let fired = await events(id, after: "overlayViewDuration")
            let closes = [VideoAd.EndReason.dismissed, .destroyed, .interrupted, .completed].contains(reason) ? 1 : 0
            #expect(fired.filter { $0 == "close" }.count == closes, "\(reason): \(fired)")
            #expect(!fired.contains("impression"))
        }
    }

    @Test func anImageAdEndedBeforeItsImpression() async throws {
        for reason in Self.reasons {
            let id = "ei-\(reason)"
            let (ad, delegate) = try await makeAd(Fixtures.ad(id: id, creative: "image"))
            // The page is told to show before the impression fires: an end there leaves the ad without one.
            ad.bridge.onSend = { [weak ad] type, _ in if type == "ad.show" { ad?.end(reason) } }
            try ad.show(in: harness.player.view)
            #expect(delegate.endReasons == [reason])
            let fired = await events(id, after: "overlayViewDuration")
            #expect(!fired.contains("close"), "an image's impression fires at show; no close stands in for it: \(reason): \(fired)")
            #expect(!fired.contains("impression"))
        }
    }

    /// `show(from:)` plus what UIKit's presentation completion does; the runner never completes a transition.
    private func presentLinear(_ ad: VideoAd) throws {
        try ad.show(from: window.root)
        ad.linearController?.loadViewIfNeeded()
        window.add(ad.bridge.webView)
        ad.reachedScreen()
    }

    /// A skip, or a close before the end, which is a skip: either way the skip is the outcome.
    @Test(arguments: [("el-skip", "video.skip", "playhead"), ("el-close", "ad.close", "reason")])
    func aLinearAdEndedBeforeItsFirstFrameFiresOnlySkip(id: String, type: String, field: String) async throws {
        let (ad, delegate) = try await makeAd(Fixtures.linearAd(id: id))
        try presentLinear(ad)
        send(ad, type, field == "playhead" ? ["playhead": 0] : ["reason": "close"])
        #expect(await waitUntil { delegate.endReasons == [.skipped] }, "\(type)")
        let fired = await events(id, after: "skip")
        #expect(!fired.contains("close"), "\(type): the skip is the outcome: \(fired)")
    }
}
}
