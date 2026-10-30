import AVFoundation
import Combine
import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// An overlay over a tracked player lives only while the content plays: a pause, the end or another item
/// ends it as `.interrupted`, `show` refuses paused content, another ad's `show` finds the screen free
/// after a pause, its `duration` counts seconds of video, and `destroy()` lets go of the player.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdContentTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameBridge.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    private let owners = Owners()
    private let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))

    final class Owners {
        var all: [VideoAds] = []
    }

    /// A custom player with a publisher, and a count of the subscriptions it still has.
    final class PublishingPlayer: VideoAdsPlayer {
        var currentTime: TimeInterval = 0
        var isPlaying = true { didSet { subject.send(isPlaying) } }
        let subject = PassthroughSubject<Bool, Never>()
        var subscriptions = 0
        var isPlayingPublisher: AnyPublisher<Bool, Never>? {
            subject.handleEvents(receiveSubscription: { [weak self] _ in self?.subscriptions += 1 },
                                 receiveCancel: { [weak self] in self?.subscriptions -= 1 }).eraseToAnyPublisher()
        }
    }

    init() {
        ContentPlayback.tickInterval = 0.02
        Environment.isWindowActive = { _ in true }
        window.add(view)
    }

    /// A loaded ad of a `VideoAds` that tracks `player` (the harness's test player when `nil`).
    private func makeAd(_ payload: [String: Any], track: ((VideoAds) -> Void)? = nil) async throws -> (VideoAd, RecordingDelegate, VideoAds) {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-c", language: "en"))
        if let track { track(ads) } else { ads.track(harness.player) }
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        ad.bridge.load()
        ad.bridge.receive(["adId": ad.id, "type": "ad.loaded"], from: sender)
        return (ad, delegate, ads)
    }

    @Test func anOverlayEndsAsInterruptedWhenTheContentPauses() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-pause"))
        try ad.show(in: view)
        await sleepMs(60)
        #expect(delegate.endReasons.isEmpty, "playing: it stays")
        harness.player.isPlaying = false
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "read on a tick, without a publisher")
        #expect(view.subviews.isEmpty && !ad.isCompleted)
        #expect(KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aPublisherEndsTheOverlayWithoutWaitingForATick() async throws {
        ContentPlayback.tickInterval = 30
        let player = PublishingPlayer()
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-pub")) { $0.track(player) }
        try ad.show(in: view)
        player.isPlaying = false
        #expect(await waitUntil(0.5) { delegate.endReasons == [.interrupted] })
    }

    @Test func showOverPausedContentThrowsAndTheAdStaysReady() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-refuse"))
        harness.player.isPlaying = false
        do {
            try ad.show(in: view)
            Issue.record("expected contentPaused")
        } catch VideoAdError.contentPaused {}
        #expect(ad.isReady && !ad.wasShown && delegate.events.isEmpty && view.subviews.isEmpty)
        harness.player.isPlaying = true
        try ad.show(in: view)
        #expect(ad.wasShown)
        try ad.dismiss()
    }

    @Test func aPauseAdShownRightAfterThePauseFindsTheScreenFree() async throws {
        ContentPlayback.tickInterval = 30   // no tick comes in between: the pause ad's show ends the overlay
        let (overlay, overlayDelegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-hand"))
        let pause = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.ad(id: "p-c-hand")), owner: ads)
        pause.bridge.load()
        pause.bridge.receive(["adId": pause.id, "type": "ad.loaded"], from: sender)
        try overlay.show(in: view)
        harness.player.isPlaying = false
        try pause.show(in: view)
        #expect(overlayDelegate.endReasons == [.interrupted], "the overlay ended first")
        #expect(KontextVideo.shared.adOnScreen === pause)
        try pause.dismiss()
    }

    @Test func aPlayingOverlayStillBlocksAnotherAd() async throws {
        let (overlay, _, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-block"))
        let pause = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.ad(id: "p-c-block")), owner: ads)
        pause.bridge.load()
        pause.bridge.receive(["adId": pause.id, "type": "ad.loaded"], from: sender)
        try overlay.show(in: view)
        do {
            try pause.show(in: view)
            Issue.record("expected anotherAdShowing")
        } catch VideoAdError.anotherAdShowing {}
        try overlay.dismiss()
    }

    @Test func theDurationCountsSecondsOfVideoNotSeeksOrStalls() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-dur", duration: 1000))
        harness.player.playhead = 10
        try ad.show(in: view)
        let elapsed = { ad.contentProgress?.elapsed ?? -1 }
        await sleepMs(150)
        #expect(elapsed() == 0 && delegate.endReasons.isEmpty, "playing but not moving (a stall): nothing counts")
        // Each step waits for a tick to take it: two steps in one tick would read as one seek.
        harness.player.playhead = 10.5
        #expect(await waitUntil { abs(elapsed() - 0.5) < 0.001 })
        harness.player.playhead = 200   // a seek forward
        await sleepMs(150)
        #expect(abs(elapsed() - 0.5) < 0.001 && delegate.endReasons.isEmpty, "the seek counts nothing")
        harness.player.playhead = 200.3
        #expect(await waitUntil { abs(elapsed() - 0.8) < 0.001 })
        #expect(delegate.endReasons.isEmpty)
        harness.player.playhead = 200.6
        #expect(await waitUntil { delegate.endReasons == [.completed] }, "1.1 s of video: the duration elapsed")
        #expect(ad.isCompleted)
    }

    @Test func anAVPlayerPauseEndsTheOverlayInTheSameTurnAndAnotherItemToo() async throws {
        let player = AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/a.mp4")))
        player.rate = 1
        let (first, firstDelegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-av1")) { $0.track(player) }
        #expect(ads.playback.isTracking && ads.playback.isPlaying)
        try first.show(in: view)
        player.pause()
        #expect(firstDelegate.endReasons == [.interrupted], "rate is observed: ended before pause() returned")
        let second = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.overlayAd(id: "o-c-av2")), owner: ads)
        let secondDelegate = RecordingDelegate()
        second.delegate = secondDelegate
        second.bridge.load()
        second.bridge.receive(["adId": second.id, "type": "ad.loaded"], from: sender)
        player.rate = 1
        try second.show(in: view)
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/b.mp4")))
        #expect(secondDelegate.endReasons == [.interrupted], "another item: another episode")
    }

    @Test func withoutATrackedPlayerTheOverlayIgnoresPauses() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-none")) { _ in }
        try ad.show(in: view)
        await sleepMs(60)
        #expect(delegate.endReasons.isEmpty)
        try ad.dismiss()
    }

    @Test func destroyAndReleaseLetGoOfThePlayerAndItsObservers() async throws {
        _ = await harness.initialize()
        let player = PublishingPlayer()
        let av = AVPlayer()
        var ads: VideoAds? = VideoAds(content: .init(id: "ep-r", language: "en"))
        weak var released = ads
        ads?.track(player)
        #expect(player.subscriptions == 1)
        ads?.destroy()
        #expect(player.subscriptions == 0 && ads?.playback.isTracking == false, "destroy cancelled the subscription")
        ads = VideoAds(content: .init(id: "ep-r2", language: "en"))
        released = ads
        ads?.track(player)
        ads?.track(av)
        #expect(player.subscriptions == 0, "tracking another player drops the first one's subscription")
        ads = nil
        #expect(released == nil, "nothing the playback holds keeps the VideoAds alive")
        av.rate = 1   // an observer left behind would call into a released object
        player.isPlaying = false
        await sleepMs(50)
    }
}
}
