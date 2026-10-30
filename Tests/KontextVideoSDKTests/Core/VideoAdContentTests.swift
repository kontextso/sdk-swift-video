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

    /// The example's bundled clip: a real movie, so AVFoundation plays it rather than failing the item.
    private static let movie = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Example/Example/Resources/sample-episode.mp4")

    /// A playing `AVPlayer` with the movie, ready before the ad is shown.
    private func playingPlayer() async throws -> AVPlayer {
        let player = AVPlayer(url: Self.movie)
        player.actionAtItemEnd = .none
        try #require(await waitUntil(5) { player.currentItem?.status == .readyToPlay }, "the movie loads")
        player.play()
        return player
    }

    private func loadedAd(_ payload: [String: Any], of ads: VideoAds) throws -> (VideoAd, RecordingDelegate) {
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        ad.bridge.load()
        ad.bridge.receive(["adId": ad.id, "type": "ad.loaded"], from: sender)
        return (ad, delegate)
    }

    @Test func anAVPlayerPauseEndsTheOverlayInTheSameTurnAndAnotherItemToo() async throws {
        ContentPlayback.tickInterval = 30
        let player = try await playingPlayer()
        defer { player.pause() }
        let (first, firstDelegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-av1")) { $0.track(player) }
        try first.show(in: view)
        player.pause()
        #expect(firstDelegate.endReasons == [.interrupted], "rate is observed: ended before pause() returned")
        let (second, secondDelegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-av2"), of: ads)
        player.play()
        try second.show(in: view)
        player.replaceCurrentItem(with: AVPlayerItem(url: Self.movie))
        #expect(secondDelegate.endReasons == [.interrupted], "another item: another episode")
    }

    @Test func theEndOfTheItemEndsTheOverlayEvenWhenTheRateStays() async throws {
        let player = try await playingPlayer()   // `actionAtItemEnd = .none`: the rate does not drop at the end
        defer { player.pause() }
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: player.currentTime().seconds + 0.4, preferredTimescale: 600)
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-end")) { $0.track(player) }
        try ad.show(in: view)
        #expect(await waitUntil(5) { delegate.endReasons == [.interrupted] }, "the item's end")
        #expect(player.rate != 0 && !ads.playback.isPlaying, "the player still asks to play, but its item ended: only the end notification told")
    }

    @Test func aQueuedCallbackOfAPlayerTrackedBeforeEndsNothing() async throws {
        ContentPlayback.tickInterval = 30
        let old = try await playingPlayer()
        let fresh = try await playingPlayer()
        defer { old.pause(); fresh.pause() }
        let (_, _, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-old")) { $0.track(old) }
        // A change on another thread: its callback reaches the main actor only after this test yields.
        let changed = DispatchSemaphore(value: 0)
        let movie = Self.movie
        DispatchQueue.global().async {
            old.replaceCurrentItem(with: AVPlayerItem(url: movie))
            changed.signal()
        }
        try #require(Self.wait(for: changed))
        ads.track(fresh)
        let (ad, delegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-new"), of: ads)
        try ad.show(in: view)
        await sleepMs(300)
        #expect(delegate.endReasons.isEmpty, "the old player's item change belongs to a binding that is gone")
        try ad.dismiss()
    }

    private nonisolated static func wait(for signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 5) == .success
    }

    /// A container whose add-subview hook the test fills: app code that runs while `show` attaches the ad.
    final class HookView: UIView {
        var onAdd: (() -> Void)?
        override func didAddSubview(_ subview: UIView) {
            super.didAddSubview(subview)
            onAdd?()
        }
    }

    @Test func aPauseWhileTheOverlayIsAttachedEndsItBeforeAnImpression() async throws {
        let player = try await playingPlayer()
        defer { player.pause() }
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-hook")) { $0.track(player) }
        let container = HookView(frame: view.bounds)
        window.add(container)
        var endedInThePause = false
        container.onAdd = {
            player.pause()
            endedInThePause = ad.hasEnded
        }
        try ad.show(in: container)
        #expect(endedInThePause, "the pause ended the overlay, reserved but not yet presented")
        #expect(delegate.events == ["end:interrupted"] && container.subviews.isEmpty, "no impression over paused content")
    }

    @Test func aPauseNoCallbackReportedDuringTheAttachEndsItBeforeAnImpression() async throws {
        ContentPlayback.tickInterval = 30   // a custom player without a publisher: only the check after the attach sees it
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-hook2"))
        let container = HookView(frame: view.bounds)
        window.add(container)
        container.onAdd = { self.harness.player.isPlaying = false }
        try ad.show(in: container)
        #expect(delegate.events == ["end:interrupted"] && container.subviews.isEmpty)
    }

    @Test func trackingAnotherPlayerEndsTheOverlayThatFollowedTheFirst() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-retrack"))
        try ad.show(in: view)
        ads.track(TestPlayer())
        #expect(delegate.endReasons == [.interrupted])
        #expect(!ads.playback.isTicking, "nothing on screen: no ticks")
    }

    @Test func aPlayerThatIsGoneEndsTheOverlayAndRefusesTheNext() async throws {
        var player: TestPlayer? = TestPlayer()
        weak var released: TestPlayer?
        released = player
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-gone", duration: 1000)) { $0.track(player!) }
        try ad.show(in: view)
        player = nil
        #expect(released == nil)
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "no content left under it, and no wall-time expiry either")
        let (next, _) = try loadedAd(Fixtures.overlayAd(id: "o-c-gone2"), of: ads)
        do {
            try next.show(in: view)
            Issue.record("expected contentPaused")
        } catch VideoAdError.contentPaused {}
    }

    @Test func aShortSeekCountsNothingAndALateSampleOfRealPlaybackCounts() {
        let seek = ContentProgress(duration: 1, at: 10)
        #expect(!seek.advance(to: 11.5, counting: true) && seek.elapsed == 0, "1.5 s at once, before any time passed: a seek")
        let late = ContentProgress(duration: 10, at: 0)
        advanceClock(by: 3)
        #expect(!late.advance(to: 3, counting: true) && late.elapsed == 3, "3 s of video after 3 s: playback, sampled late")
        let jumped = ContentProgress(duration: 10, at: 0)
        advanceClock(by: 1)
        jumped.resync(to: 0.8)   // an AVPlayer time jump
        #expect(!jumped.advance(to: 0.8, counting: true) && jumped.elapsed == 0)
    }

    @Test func aPublishedPauseEndsTheOverlayEvenIfPlaybackResumesBeforeDelivery() async throws {
        ContentPlayback.tickInterval = 30
        let player = PublishingPlayer()
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-flicker")) { $0.track(player) }
        try ad.show(in: view)
        player.isPlaying = false
        player.isPlaying = true
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "the pause was published: it counts")
    }

    /// Ends nothing but calls back: the app's `didEnd` for the reentrancy cases.
    final class EndHook: VideoAdDelegate {
        var onEnd: (() -> Void)?
        func videoAd(_ ad: VideoAd, didEnd reason: VideoAd.EndReason) { onEnd?() }
    }

    /// A player whose `isPlaying` getter runs app code.
    final class HookPlayer: VideoAdsPlayer {
        var currentTime: TimeInterval = 0
        var onRead: (() -> Void)?
        var isPlaying: Bool {
            onRead?()
            return true
        }
    }

    @Test func anOverlaysDidEndThatDestroysTheIncomingAdsOwnerStopsItsShow() async throws {
        ContentPlayback.tickInterval = 30
        let (overlay, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-re1"))
        let (pause, pauseDelegate, pauseOwner) = try await makeAd(Fixtures.ad(id: "p-c-re1"))
        let hook = EndHook()
        hook.onEnd = { pauseOwner.destroy() }
        overlay.delegate = hook
        try overlay.show(in: view)
        harness.player.isPlaying = false
        do {
            try pause.show(in: view)
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
        #expect(!pause.wasShown && pauseDelegate.events.isEmpty && view.subviews.isEmpty && KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aPlayingGetterThatDestroysTheOwnerStopsTheShow() async throws {
        let player = HookPlayer()
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-re2")) { $0.track(player) }
        player.onRead = { [weak ads, weak player] in
            player?.onRead = nil
            ads?.destroy()
        }
        do {
            try ad.show(in: view)
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
        #expect(ads.isDestroyed && !ad.wasShown && delegate.events.isEmpty && view.subviews.isEmpty)
    }

    @Test func anAdShownAndEndedInsideTheHandoverIsNotReservedAgain() async throws {
        ContentPlayback.tickInterval = 30
        let (overlay, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-re3"))
        let (pause, pauseDelegate, owner) = try await makeAd(Fixtures.ad(id: "p-c-re3"))
        let hook = EndHook()
        hook.onEnd = {
            try? pause.show(in: self.view)
            try? pause.dismiss()
        }
        overlay.delegate = hook
        try overlay.show(in: view)
        harness.player.isPlaying = false
        do {
            try pause.show(in: view)
            Issue.record("expected alreadyShown")
        } catch VideoAdError.alreadyShown {}
        #expect(pause.hasEnded && pauseDelegate.endReasons == [.dismissed])
        #expect(KontextVideo.shared.adOnScreen == nil, "an ended ad never takes the slot again")
        owner.destroy()
        #expect(KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aDestroyInTheOverlaysDidEndWhileTrackingAnotherPlayerLeavesNothingSubscribed() async throws {
        let (ad, _, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-re4"))
        let hook = EndHook()
        hook.onEnd = { ads.destroy() }
        ad.delegate = hook
        try ad.show(in: view)
        let next = PublishingPlayer()
        ads.track(next)
        #expect(ads.isDestroyed && !ads.playback.isTracking && next.subscriptions == 0)
    }

    @Test func aTrackInTheOverlaysDidEndWinsOverTheTrackThatEndedIt() async throws {
        let (first, _, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-re5"))
        let middle = PublishingPlayer()
        let last = PublishingPlayer()
        last.currentTime = 100
        let hook = EndHook()
        hook.onEnd = { ads.track(last) }
        first.delegate = hook
        try first.show(in: view)
        ads.track(middle)
        #expect(middle.subscriptions == 0 && last.subscriptions == 1 && ads.playback.playhead == 100)
        let (second, delegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-re5b"), of: ads)
        try second.show(in: view)
        middle.isPlaying = false
        await sleepMs(150)
        #expect(delegate.endReasons.isEmpty, "the player tracked first and replaced does not end the last one's overlay")
        try second.dismiss()
    }

    @Test func aQueuedEndOfTheItemBeforeEndsNothingOnTheNextItem() async throws {
        ContentPlayback.tickInterval = 30
        let player = try await playingPlayer()
        defer { player.pause() }
        let oldItem = try #require(player.currentItem)
        let (first, firstDelegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-item1")) { $0.track(player) }
        try first.show(in: view)
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: oldItem)
            posted.signal()
        }
        try #require(Self.wait(for: posted))
        player.replaceCurrentItem(with: AVPlayerItem(url: Self.movie))
        #expect(firstDelegate.endReasons == [.interrupted])
        let (second, delegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-item2"), of: ads)
        player.play()
        try second.show(in: view)
        await sleepMs(300)
        #expect(delegate.endReasons.isEmpty, "the end belonged to the item before")
        try second.dismiss()
    }

    @Test func anEndedItemRefusesTheNextOverlayUntilItPlaysAgain() async throws {
        let player = try await playingPlayer()
        defer { player.pause() }
        let (first, firstDelegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-ended1")) { $0.track(player) }
        try first.show(in: view)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: player.currentTime().seconds + 0.2, preferredTimescale: 600)
        try #require(await waitUntil(5) { firstDelegate.endReasons == [.interrupted] })
        #expect(player.rate != 0, "actionAtItemEnd .none keeps the rate")
        let (next, delegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-ended2"), of: ads)
        do {
            try next.show(in: view)
            Issue.record("expected contentPaused")
        } catch VideoAdError.contentPaused {}
        #expect(next.isReady && delegate.events.isEmpty)
        player.currentItem?.forwardPlaybackEndTime = .invalid
        await player.seek(to: .zero)   // the app plays it again
        #expect(await waitUntil(2) { ads.playback.isPlaying })
        try next.show(in: view)
        try next.dismiss()
    }

    @Test func videoPlayedWhileTheSceneWasInactiveCountsNothingOnReturn() async throws {
        ContentPlayback.tickInterval = 30   // no tick runs while the app is suspended
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-scene", duration: 1000))
        try ad.show(in: view)
        let scene = try #require(window.window.windowScene)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(ad.clock?.isCounting == false)
        advanceClock(by: 3)
        harness.player.playhead = 3   // background audio played on
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        ad.contentDidChange(.tick)
        #expect(ad.contentProgress?.elapsed == 0 && delegate.endReasons.isEmpty)
        try ad.dismiss()
    }

    @Test func fasterPlaybackCountsItsVideoSeconds() {
        let unknown = ContentProgress(duration: 10, at: 0)
        let known = ContentProgress(duration: 100, at: 0)
        for second in 1...4 {
            advanceClock(by: 0.25)
            _ = unknown.advance(to: Double(second), counting: true)              // 4×, speed not told
            _ = known.advance(to: Double(second) * 2, counting: true, rate: 8)   // 8×, an AVPlayer's rate
        }
        #expect(abs(unknown.elapsed - 4) < 0.001 && abs(known.elapsed - 8) < 0.001)
        let seek = ContentProgress(duration: 10, at: 0)
        advanceClock(by: 0.25)
        #expect(!seek.advance(to: 2, counting: true, rate: 1) && seek.elapsed == 0, "2 s in a quarter second at 1×: a seek")
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
