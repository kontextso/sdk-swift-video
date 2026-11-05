import AVFoundation
import Combine
import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// An overlay over a tracked player lives only while the content plays: a pause, the end or another item
/// ends it as `.interrupted`, `show` refuses paused content, another ad's `show` finds the screen free
/// after a pause, its `duration` counts seconds of video, and `destroy()` lets go of the player. A pause ad
/// over a tracked player ends as `.interrupted` once the content plays again.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdContentTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    private let owners = Owners()
    private let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))

    final class Owners {
        var all: [VideoAds] = []
    }

    /// A custom player with a publisher, and a count of the subscriptions it still has.
    final class PublishingPlayer: ContentPlayer {
        var currentTime: TimeInterval = 0
        var isPlaying = true { didSet { subject.send(isPlaying) } }
        let subject = PassthroughSubject<Bool, Never>()
        var subscriptions = 0
        var isPlayingPublisher: AnyPublisher<Bool, Never>? {
            subject.handleEvents(receiveSubscription: { [weak self] _ in self?.subscriptions += 1 },
                                 receiveCancel: { [weak self] in self?.subscriptions -= 1 }).eraseToAnyPublisher()
        }
    }

    /// A custom player that reports what it does: its speed, its seeks and its item changes.
    final class ReportingPlayer: ContentPlayer {
        var currentTime: TimeInterval = 0
        var isPlaying = true
        var playbackSpeed: Double? = 1
        let seeks = PassthroughSubject<Void, Never>()
        let changes = PassthroughSubject<Void, Never>()
        var seekPublisher: AnyPublisher<Void, Never>? { seeks.eraseToAnyPublisher() }
        var contentChangedPublisher: AnyPublisher<Void, Never>? { changes.eraseToAnyPublisher() }
    }

    /// A custom player that declares its publisher with the wrong type: not the protocol's requirement.
    final class MistypedPlayer: ContentPlayer {
        var currentTime: TimeInterval = 0
        var isPlaying = true
        var isPlayingPublisher: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
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

    @Test func theFirstTrackWhileAnOverlayIsUpLeavesItOnScreen() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-late")) { _ in }
        try ad.show(in: view)
        ads.track(harness.player)   // a player made after the overlay went up
        await sleepMs(100)
        #expect(delegate.endReasons.isEmpty, "only a player replacing another hands the overlay over")
        ads.track(TestPlayer())
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "another player: the overlay ends")
    }

    @Test func anOverlayShownBeforeTrackSaysItsDurationCountsOnScreenTime() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-untracked", duration: 60_000)) { _ in }
        var warnings: [String] = []
        Logger.level = .warning
        Logger.sink = { level, message in if level == .warning { warnings.append(message) } }
        defer { Logger.sink = nil }
        try ad.show(in: view)
        let expected = "overlay \(ad.id.prefix(8)) shown before track(): its duration counts on-screen time, not video time"
        #expect(warnings.filter { $0.contains("before track()") } == [expected], "once, at show")
        #expect(ad.wasShown && !ad.hasEnded && delegate.endReasons.isEmpty && ad.onScreenClock != nil, "shown as before, on its clock")
        ad.dismiss()
    }

    @Test func aTrackedOverlayDoesNotWarn() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-tracked", duration: 60_000))
        var warnings: [String] = []
        Logger.level = .warning
        Logger.sink = { level, message in if level == .warning { warnings.append(message) } }
        defer { Logger.sink = nil }
        try ad.show(in: view)
        #expect(ad.wasShown && !ad.hasEnded)
        #expect(!warnings.contains { $0.contains("before track()") }, "tracked: no warning")
        ad.dismiss()
    }

    @Test func anOverlayShownBeforeTheFirstTrackFollowsTheContentFromThenOnActiveTime() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-late2", duration: 60_000)) { _ in }
        try ad.show(in: view)
        let clock = try #require(ad.onScreenClock)
        #expect(clock.timer != nil, "no player at show: the duration counts active time")
        ads.track(harness.player)   // a player made after the overlay went up
        #expect(ads.playback.isTicking, "the track starts the ticks")
        await sleepMs(60)
        #expect(delegate.endReasons.isEmpty)
        #expect(ad.contentClock == nil && clock.timer != nil, "the duration stays on active time, as chosen at show")
        harness.player.isPlaying = false
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "from the track on it follows the content: a pause ends it")
    }

    @Test func aPublisherEndsTheOverlayWithoutWaitingForATick() async throws {
        ContentPlayback.tickInterval = 30
        let player = PublishingPlayer()
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-pub")) { $0.track(player) }
        try ad.show(in: view)
        player.isPlaying = false
        #expect(await waitUntil(0.5) { delegate.endReasons == [.interrupted] })
    }

    @Test func aMistypedPublisherFallsBackWithOneWarning() async throws {
        let player = MistypedPlayer()
        let (_, _, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-mistyped")) { $0.track(player) }
        var lines: [(KontextVideo.Configuration.LogLevel, String)] = []
        Logger.level = .warning
        Logger.sink = { lines.append(($0, $1)) }
        defer { Logger.sink = nil }
        ads.track(player)
        ads.track(player)
        let warnings = lines.filter { $0.0 == .warning && $0.1.contains("isPlayingPublisher") }
        // The first track, in makeAd, already said it: once per process. Said again after a reset only.
        #expect(warnings.isEmpty, "\(lines)")
        PlayerFallback.noted = []
        ads.track(player)
        ads.track(player)
        let again = lines.filter { $0.0 == .warning && $0.1.contains("isPlayingPublisher") }
        #expect(again.count == 1 && again[0].1.contains("MistypedPlayer"), "once, naming the type: \(lines)")
    }

    @Test func aReportedSeekCountsNothingOfTheOverlaysDuration() async throws {
        ContentPlayback.tickInterval = 30   // the ticks below are delivered by hand
        let player = ReportingPlayer()
        player.currentTime = 10
        let (ad, _, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-seek", duration: 1000)) { $0.track(player) }
        try ad.show(in: view)
        let elapsed = { ad.contentClock?.elapsed ?? -1 }
        await sleepMs(100)
        player.currentTime = 10.3   // small enough to pass for playback
        player.seeks.send()
        #expect(await waitUntil { ads.playback.isTracking })
        await sleepMs(50)   // the seek is delivered on the main queue
        ads.playback.onChange?(.tick)
        #expect(elapsed() == 0, "the seek was reported: nothing counts")
        await sleepMs(100)
        player.currentTime = 10.4
        ads.playback.onChange?(.tick)
        #expect(abs(elapsed() - 0.1) < 0.001, "playback after it counts")
        ad.dismiss()
    }

    @Test func aReportedItemChangeEndsTheOverlayAndTheSpeedIsRead() async throws {
        ContentPlayback.tickInterval = 30
        let player = ReportingPlayer()
        player.playbackSpeed = 2
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-item")) { $0.track(player) }
        #expect(ads.playback.rate == 2, "the player's own speed, not the 4× guess")
        try ad.show(in: view)
        player.changes.send()
        #expect(await waitUntil(0.5) { delegate.endReasons == [.interrupted] }, "without waiting for a tick")
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
        ad.dismiss()
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
        pause.dismiss()
    }

    @Test func aPauseAdEndsWhenTheNextPageOfAFeedTakesThePlayer() async throws {
        harness.player.isPlaying = false
        let (pause, delegate, _) = try await makeAd(Fixtures.ad(id: "p-c-feed"))
        try pause.show(in: view)
        // The next page, still attached in the pager, takes the one shared player and plays it.
        let next = VideoAds(content: .init(id: "ep-next", language: "en"))
        owners.all.append(next)
        next.track(harness.player)
        harness.player.isPlaying = true
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "its episode is gone from the player")
        #expect(KontextVideo.shared.adOnScreen == nil, "the next page's ad can show")
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
        overlay.dismiss()
    }

    @Test func theDurationCountsSecondsOfVideoNotSeeksOrStalls() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-dur", duration: 1000))
        harness.player.playhead = 10
        try ad.show(in: view)
        let elapsed = { ad.contentClock?.elapsed ?? -1 }
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
        try #require(await waitUntil { player.currentItem?.status == .readyToPlay }, "the movie loads")
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
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "the item's end")
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
        ad.dismiss()
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

    @Test func anAVPlayerThatIsGoneEndsTheOverlayAndRefusesTheNext() async throws {
        var player: AVPlayer? = try await playingPlayer()
        weak var released: AVPlayer?
        released = player
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-gone", duration: 1000)) { $0.track(player!) }
        try ad.show(in: view)
        player?.pause()
        player = nil
        #expect(await waitUntil { released == nil }, "an AVPlayer is the app's: held weakly")
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "no content left under it, and no wall-time expiry either")
        let (next, _) = try loadedAd(Fixtures.overlayAd(id: "o-c-gone2"), of: ads)
        do {
            try next.show(in: view)
            Issue.record("expected contentPaused")
        } catch VideoAdError.contentPaused {}
    }

    @Test func aWrapperOnlyTheSDKHoldsKeepsWorkingUntilDestroy() async throws {
        weak var released: TestPlayer?
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-wrap", duration: 1000)) { ads in
            let wrapper = TestPlayer()
            wrapper.playhead = 12
            released = wrapper
            ads.track(wrapper)
        }
        #expect(released != nil, "held by the SDK")
        #expect(ads.playback.isPlaying && ads.playhead == 12)
        try ad.show(in: view)
        await sleepMs(60)
        #expect(delegate.endReasons.isEmpty, "the content still plays under the overlay")
        ad.dismiss()
        ads.track(TestPlayer())
        #expect(released == nil, "the next track lets go of it")
        weak var second: TestPlayer?
        do {
            let wrapper = TestPlayer()
            second = wrapper
            ads.track(wrapper)
        }
        ads.destroy()
        #expect(second == nil, "destroy lets go of it")
    }

    @Test func aShortSeekCountsNothingAndALateSampleOfRealPlaybackCounts() {
        let seek = ContentTimeClock(duration: 1, at: 10)
        #expect(!seek.advance(to: 11.5, isCounting: true) && seek.elapsed == 0, "1.5 s at once, before any time passed: a seek")
        let late = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 3)
        #expect(!late.advance(to: 3, isCounting: true) && late.elapsed == 3, "3 s of video after 3 s: playback, sampled late")
        let jumped = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 1)
        jumped.resync(to: 0.8)   // an AVPlayer time jump
        #expect(!jumped.advance(to: 0.8, isCounting: true) && jumped.elapsed == 0)
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
    final class HookPlayer: ContentPlayer {
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
        let (pause, pauseDelegate, pauseOwner) = try await makeAd(Fixtures.ad(id: "p-c-re1")) { $0.track(TestPlayer()) }   // a player is one VideoAds's
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
        let (pause, pauseDelegate, owner) = try await makeAd(Fixtures.ad(id: "p-c-re3")) { $0.track(TestPlayer()) }   // a player is one VideoAds's
        let hook = EndHook()
        hook.onEnd = {
            try? pause.show(in: self.view)
            pause.dismiss()
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
        second.dismiss()
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
        // Another item is another episode: its ads come once it is tracked for it.
        ads.track(player)
        let (second, delegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-item2"), of: ads)
        player.play()
        try second.show(in: view)
        await sleepMs(300)
        #expect(delegate.endReasons.isEmpty, "the end belonged to the item before")
        second.dismiss()
    }

    @Test func anEndedItemRefusesTheNextOverlayUntilItPlaysAgain() async throws {
        let player = try await playingPlayer()
        defer { player.pause() }
        let (first, firstDelegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-ended1")) { $0.track(player) }
        try first.show(in: view)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: player.currentTime().seconds + 0.2, preferredTimescale: 600)
        try #require(await waitUntil { firstDelegate.endReasons == [.interrupted] })
        #expect(player.rate != 0, "actionAtItemEnd .none keeps the rate")
        let (next, delegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-ended2"), of: ads)
        do {
            try next.show(in: view)
            Issue.record("expected contentPaused")
        } catch VideoAdError.contentPaused {}
        #expect(next.isReady && delegate.events.isEmpty)
        // A pause and a play without a seek restart nothing: the item is still past its end.
        player.pause()
        player.play()
        await sleepMs(100)
        do {
            try next.show(in: view)
            Issue.record("expected contentPaused after pause and play")
        } catch VideoAdError.contentPaused {}
        player.currentItem?.forwardPlaybackEndTime = .invalid
        await player.seek(to: .zero)   // the app plays it again
        #expect(await waitUntil { ads.playback.isPlaying })
        try next.show(in: view)
        next.dismiss()
    }

    @Test func videoPlayedWhileTheSceneWasInactiveCountsNothingOnReturn() async throws {
        ContentPlayback.tickInterval = 30   // no tick runs while the app is suspended
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-scene", duration: 1000))
        try ad.show(in: view)
        let scene = try #require(window.window.windowScene)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(ad.onScreenClock?.isCounting == false)
        advanceClock(by: 3)
        harness.player.playhead = 3   // background audio played on
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        ad.contentDidChange(.tick)
        #expect(ad.contentClock?.elapsed == 0 && delegate.endReasons.isEmpty)
        ad.dismiss()
    }

    /// The scene of the test window leaves (the app goes to the background) or comes back.
    private func setSceneActive(_ active: Bool) throws {
        let scene = try #require(window.window.windowScene)
        NotificationCenter.default.post(name: active ? UIScene.didActivateNotification : UIScene.willDeactivateNotification, object: scene)
    }

    @Test func aPauseInTheBackgroundFreezesTheOverlayAndItGoesOnWhenTheAppPlaysOnReturn() async throws {
        VideoAd.contentResumeGrace = 0.1
        defer { VideoAd.contentResumeGrace = 1 }
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-bg-on", duration: 1000))
        try ad.show(in: view)
        try setSceneActive(false)
        harness.player.isPlaying = false   // iOS paused the player as the app left
        ad.contentDidChange(.playingChanged(isPlaying: false))
        ad.contentDidChange(.tick)
        await sleepMs(60)   // the ticks read the pause too
        #expect(delegate.endReasons.isEmpty && view.subviews.count == 1, "frozen, not ended")
        try setSceneActive(true)
        harness.player.isPlaying = true   // the app plays the content again on return
        ad.contentDidChange(.tick)
        #expect(!ad.wasContentPausedWhileInactive)
        await sleepMs(250)   // past the grace
        #expect(delegate.endReasons.isEmpty)
        harness.player.playhead = 0.5
        #expect(await waitUntil { abs((ad.contentClock?.elapsed ?? 0) - 0.5) < 0.001 }, "the duration counts on")
        harness.player.isPlaying = false
        ad.contentDidChange(.playingChanged(isPlaying: false))
        #expect(delegate.endReasons == [.interrupted], "a pause in the foreground ends it at once, as always")
    }

    @Test func theCheckAfterTheGraceLetsAnOverlayGoOnOverContentPlayingAgain() async throws {
        ContentPlayback.tickInterval = 30   // no tick and no publisher: only the check after the grace reads it
        VideoAd.contentResumeGrace = 0.05
        defer { VideoAd.contentResumeGrace = 1 }
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-bg-check"))
        try ad.show(in: view)
        try setSceneActive(false)
        harness.player.isPlaying = false
        ad.contentDidChange(.playingChanged(isPlaying: false))
        try setSceneActive(true)
        harness.player.isPlaying = true
        #expect(await waitUntil { !ad.wasContentPausedWhileInactive && ad.contentRecheck == nil })
        #expect(delegate.endReasons.isEmpty)
        ad.contentDidChange(.playingChanged(isPlaying: false))
        #expect(delegate.endReasons == [.interrupted])
    }

    @Test func anOverlayStillPausedAfterTheGraceOnReturnEndsAsInterrupted() async throws {
        VideoAd.contentResumeGrace = 0.3
        defer { VideoAd.contentResumeGrace = 1 }
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-bg-off"))
        try ad.show(in: view)
        try setSceneActive(false)
        harness.player.isPlaying = false
        ad.contentDidChange(.playingChanged(isPlaying: false))
        try setSceneActive(true)
        // Within the grace the pause holds, however the content reports it.
        ad.contentDidChange(.tick)
        ad.contentDidChange(.playingChanged(isPlaying: false))
        #expect(delegate.endReasons.isEmpty)
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "still paused after the grace")
        #expect(view.subviews.isEmpty && KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aSceneThatLeavesAgainDuringTheGraceKeepsTheOverlayFrozen() async throws {
        VideoAd.contentResumeGrace = 0.05
        defer { VideoAd.contentResumeGrace = 1 }
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-bg-again"))
        try ad.show(in: view)
        try setSceneActive(false)
        harness.player.isPlaying = false
        ad.contentDidChange(.playingChanged(isPlaying: false))
        try setSceneActive(true)
        try setSceneActive(false)
        await sleepMs(200)
        #expect(delegate.endReasons.isEmpty && ad.wasContentPausedWhileInactive)
        try setSceneActive(true)
        #expect(await waitUntil { delegate.endReasons == [.interrupted] })
    }

    @Test func otherContentChangesInTheBackgroundEndTheOverlayAsBefore() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-c-bg-other1"))
        try ad.show(in: view)
        try setSceneActive(false)
        ad.contentDidChange(.seeked)
        #expect(delegate.endReasons.isEmpty, "a jump never ended it")
        ad.contentDidChange(.contentChanged)
        #expect(delegate.endReasons == [.interrupted])
        try setSceneActive(true)
        let (frozen, frozenDelegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-bg-other2"))
        try frozen.show(in: view)
        try setSceneActive(false)
        harness.player.isPlaying = false
        frozen.contentDidChange(.playingChanged(isPlaying: false))
        frozen.contentDidChange(.contentEnded)
        #expect(frozenDelegate.endReasons == [.interrupted], "the end of the content ends a frozen overlay too")
        try setSceneActive(true)
        let (third, thirdDelegate) = try loadedAd(Fixtures.overlayAd(id: "o-c-bg-other3"), of: ads)
        harness.player.isPlaying = true
        try third.show(in: view)
        try setSceneActive(false)
        harness.player.isPlaying = false
        third.contentDidChange(.playingChanged(isPlaying: false))
        ads.destroy()
        #expect(thirdDelegate.endReasons == [.destroyed], "destroy ends a frozen overlay")
        try setSceneActive(true)
    }

    @Test func fasterPlaybackCountsItsVideoSeconds() {
        let unknown = ContentTimeClock(duration: 10, at: 0)
        let known = ContentTimeClock(duration: 100, at: 0)
        for second in 1...4 {
            advanceClock(by: 0.25)
            _ = unknown.advance(to: Double(second), isCounting: true)              // 4×, speed not told
            _ = known.advance(to: Double(second) * 2, isCounting: true, rate: 8)   // 8×, an AVPlayer's rate
        }
        #expect(abs(unknown.elapsed - 4) < 0.001 && abs(known.elapsed - 8) < 0.001)
        let seek = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 0.25)
        #expect(!seek.advance(to: 2, isCounting: true, rate: 1) && seek.elapsed == 0, "2 s in a quarter second at 1×: a seek")
    }

    /// A player whose publisher runs app code when it is read and when it is subscribed to.
    final class SetupHookPlayer: ContentPlayer {
        var currentTime: TimeInterval = 1
        var isPlaying = true
        var onRead: (() -> Void)?
        var onSubscribe: (() -> Void)?
        var onCancel: (() -> Void)?
        var subscriptions = 0
        let subject = PassthroughSubject<Bool, Never>()
        var isPlayingPublisher: AnyPublisher<Bool, Never>? {
            onRead?()
            return subject.handleEvents(receiveSubscription: { [weak self] _ in
                self?.subscriptions += 1
                self?.onSubscribe?()
            }, receiveCancel: { [weak self] in
                self?.subscriptions -= 1
                self?.onCancel?()
            }).eraseToAnyPublisher()
        }
    }

    @Test func aDestroyWhileThePublisherIsReadLeavesNoSubscription() async {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-setup1", language: "en"))
        let player = SetupHookPlayer()
        player.onRead = { [weak ads] in ads?.destroy() }
        ads.track(player)
        #expect(ads.isDestroyed && !ads.playback.isTracking && player.subscriptions == 0)
    }

    @Test func aDestroyWhileSubscribingLeavesNoSubscription() async {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-setup2", language: "en"))
        let player = SetupHookPlayer()
        player.onSubscribe = { [weak ads] in ads?.destroy() }
        ads.track(player)
        #expect(ads.isDestroyed && !ads.playback.isTracking && player.subscriptions == 0)
    }

    @Test func aTrackWhileThePublisherIsReadKeepsTheLastPlayersSubscription() async {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-setup3", language: "en"))
        defer { ads.destroy() }
        let middle = SetupHookPlayer()
        let last = SetupHookPlayer()
        last.currentTime = 99
        middle.onRead = { [weak ads] in ads?.track(last) }
        ads.track(middle)
        #expect(ads.playback.playhead == 99 && last.subscriptions == 1 && middle.subscriptions == 0)
    }

    @Test func aDestroyInTheOldSubscriptionsCancellationLeavesNothingTracked() async {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-cancel1", language: "en"))
        let first = SetupHookPlayer()
        let next = SetupHookPlayer()
        first.onCancel = { [weak ads] in ads?.destroy() }
        ads.track(first)
        ads.track(next)   // cancels the first player's subscription, which destroys
        #expect(ads.isDestroyed && !ads.playback.isTracking && next.subscriptions == 0 && first.subscriptions == 0)
    }

    @Test func aTrackInTheOldSubscriptionsCancellationWins() async {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-cancel2", language: "en"))
        defer { ads.destroy() }
        let first = SetupHookPlayer()
        let middle = SetupHookPlayer()
        let last = SetupHookPlayer()
        last.currentTime = 77
        first.onCancel = { [weak ads] in ads?.track(last) }
        ads.track(first)
        ads.track(middle)
        #expect(ads.playback.playhead == 77 && last.subscriptions == 1 && middle.subscriptions == 0)
    }

    @Test func aTrackInTheOldSubscriptionsCancellationEndsTheOverlayOnScreen() async throws {
        let first = SetupHookPlayer()
        let middle = SetupHookPlayer()
        let last = SetupHookPlayer()
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-cancel")) { $0.track(first) }
        try ad.show(in: view)
        first.onCancel = { [weak ads] in ads?.track(last) }
        ads.track(middle)   // cancels the first player's subscription, which tracks the last one
        #expect(delegate.endReasons == [.interrupted], "the overlay followed the first player")
        #expect(KontextVideo.shared.adOnScreen == nil && last.subscriptions == 1 && middle.subscriptions == 0)
    }

    @Test func aTrackInTheCancellationThatDestroyRunsTracksNothing() async {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-cancel3", language: "en"))
        let first = SetupHookPlayer()
        let next = SetupHookPlayer()
        first.onCancel = { [weak ads] in ads?.track(next) }
        ads.track(first)
        ads.destroy()
        #expect(!ads.playback.isTracking && next.subscriptions == 0)
    }

    @Test func trackAfterDestroyDoesNothing() async throws {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: "ep-after-destroy", language: "en"))
        ads.destroy()
        let custom = SetupHookPlayer()
        ads.track(custom)
        #expect(!ads.playback.isTracking && custom.subscriptions == 0)
        ads.track(AVPlayer())
        #expect(!ads.playback.isTracking)
    }

    @Test func withoutATrackedPlayerTheOverlayIgnoresPauses() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o-c-none")) { _ in }
        try ad.show(in: view)
        #expect(!ads.playback.isTicking, "no player to watch: no ticks")
        await sleepMs(60)
        #expect(delegate.endReasons.isEmpty)
        ad.dismiss()
    }

    // MARK: A pause ad follows the content the other way

    @Test func aPauseAdEndsAsInterruptedWhenTheContentPlaysAgain() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p-c-resume"))
        harness.player.isPlaying = false
        try ad.show(in: view)
        await sleepMs(60)
        #expect(delegate.endReasons.isEmpty, "paused: it stays")
        harness.player.isPlaying = true   // resumed outside the app's code: lock screen, headset, PiP
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "read on a tick, without a publisher")
        #expect(view.subviews.isEmpty && KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aPublisherEndsThePauseAdWithoutWaitingForATick() async throws {
        ContentPlayback.tickInterval = 30
        let player = PublishingPlayer()
        player.isPlaying = false
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p-c-pub")) { $0.track(player) }
        try ad.show(in: view)
        player.isPlaying = true
        #expect(await waitUntil(0.5) { delegate.endReasons == [.interrupted] })
    }

    @Test func anAVPlayerPlayEndsThePauseAd() async throws {
        let player = try await playingPlayer()
        player.pause()
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p-c-av")) { $0.track(player) }
        try ad.show(in: view)
        player.play()
        #expect(await waitUntil { delegate.endReasons == [.interrupted] })
        player.pause()
    }

    @Test func aPauseAdShownOverPlayingContentWaitsForAPauseFirst() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p-c-over"))
        try ad.show(in: view)   // the player still reports playing: a rate change is not a resume
        await sleepMs(80)
        #expect(delegate.endReasons.isEmpty)
        harness.player.isPlaying = false
        await sleepMs(80)
        #expect(delegate.endReasons.isEmpty)
        harness.player.isPlaying = true
        #expect(await waitUntil { delegate.endReasons == [.interrupted] })
    }

    @Test func anOverlayShownRightAfterThePlayFindsTheScreenFree() async throws {
        ContentPlayback.tickInterval = 30   // no tick comes in between: the overlay's show ends the pause ad
        let (pause, pauseDelegate, ads) = try await makeAd(Fixtures.ad(id: "p-c-hand2"))
        let overlay = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.overlayAd(id: "o-c-hand2")), owner: ads)
        overlay.bridge.load()
        overlay.bridge.receive(["adId": overlay.id, "type": "ad.loaded"], from: sender)
        harness.player.isPlaying = false
        try pause.show(in: view)
        harness.player.isPlaying = true
        try overlay.show(in: view)
        #expect(pauseDelegate.endReasons == [.interrupted], "the pause ad ended first")
        #expect(KontextVideo.shared.adOnScreen === overlay)
        overlay.dismiss()
    }

    @Test func withoutATrackedPlayerThePauseAdIgnoresPlayback() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p-c-none")) { _ in }
        try ad.show(in: view)
        await sleepMs(60)
        #expect(delegate.endReasons.isEmpty)
        ad.dismiss()
    }

    /// A player model that owns its `VideoAds` and is its tracked player: the cycle the docs warn about.
    final class OwningPlayer: ContentPlayer {
        var ads: VideoAds?
        var currentTime: TimeInterval { 0 }
        var isPlaying: Bool { true }
    }

    @Test func aCustomPlayerThatReferencesItsVideoAdsIsFreedByDestroy() async throws {
        _ = await harness.initialize()
        weak var weakAds: VideoAds?
        weak var weakPlayer: OwningPlayer?
        do {
            let player = OwningPlayer()
            let ads = VideoAds(content: .init(id: "ep-cycle", language: "en"))
            player.ads = ads
            ads.track(player)
            weakAds = ads
            weakPlayer = player
        }
        #expect(weakAds != nil && weakPlayer != nil, "the cycle the docs describe: releasing alone frees nothing")
        weakAds?.destroy()
        #expect(weakAds == nil && weakPlayer == nil, "destroy() breaks it: both are freed")
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
