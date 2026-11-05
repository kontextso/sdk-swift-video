import AVFoundation
import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// An episode's ads only in that episode: a player belongs to one `VideoAds` at a time, and an overlay or
/// pause ad whose episode no longer plays in the tracked player throws `invalidated(.contentChanged)` at
/// `show`. Linear ads are not checked.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdEpisodeTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    private let owners = Owners()
    private let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))

    final class Owners {
        var all: [VideoAds] = []
    }

    /// The example's bundled clip: a real movie, so AVFoundation plays it rather than failing the item.
    private static let movie = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Example/Example/Resources/sample-episode.mp4")

    init() {
        ContentPlayback.tickInterval = 0.02
        Environment.isWindowActive = { _ in true }
        window.add(view)
    }

    private func makeAds(_ id: String) async -> VideoAds {
        _ = await harness.initialize()
        let ads = VideoAds(content: .init(id: id, language: "en"))
        owners.all.append(ads)
        return ads
    }

    private func loadedAd(_ payload: [String: Any], of ads: VideoAds) throws -> VideoAd {
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        ad.bridge.receive(["adId": ad.id, "type": "ad.loaded"], from: sender)
        return ad
    }

    private func playingPlayer() async throws -> AVPlayer {
        let player = AVPlayer(url: Self.movie)
        player.actionAtItemEnd = .none
        try #require(await waitUntil { player.currentItem?.status == .readyToPlay }, "the movie loads")
        player.play()
        return player
    }

    private func expectContentChanged(_ ad: VideoAd, _ comment: Comment) {
        do {
            try ad.show(in: view)
            Issue.record("expected invalidated(.contentChanged): \(comment)")
        } catch VideoAdError.invalidated(.contentChanged) {} catch { Issue.record("expected invalidated(.contentChanged), got \(error)") }
        #expect(ad.invalidationReason == .contentChanged && !ad.wasShown && view.subviews.isEmpty, comment)
    }

    @Test func aPlayerTrackedByAnotherVideoAdsMakesTheFirstOnesOverlayThrow() async throws {
        let player = TestPlayer()
        let episodeA = await makeAds("ep-a")
        episodeA.track(player)
        let overlay = try loadedAd(Fixtures.overlayAd(id: "o-ep-moved"), of: episodeA)
        let pause = try loadedAd(Fixtures.ad(id: "p-ep-moved"), of: episodeA)
        let episodeB = await makeAds("ep-b")
        episodeB.track(player)
        #expect(!episodeA.playback.isTracking && episodeB.playback.isTracking, "one VideoAds at a time")
        expectContentChanged(overlay, "the player plays episode B now")
        expectContentChanged(pause, "a pause ad too")
        // Episode A tracks a player again: its ads can be shown again.
        episodeA.track(player)
        let again = try loadedAd(Fixtures.overlayAd(id: "o-ep-back"), of: episodeA)
        try again.show(in: view)
        #expect(again.wasShown && !episodeB.playback.isTracking)
        again.dismiss()
    }

    @Test func anOverlayOnScreenEndsWhenAnotherVideoAdsTakesThePlayer() async throws {
        let player = TestPlayer()
        let episodeA = await makeAds("ep-a2")
        episodeA.track(player)
        let overlay = try loadedAd(Fixtures.overlayAd(id: "o-ep-onscreen"), of: episodeA)
        let delegate = RecordingDelegate()
        overlay.delegate = delegate
        try overlay.show(in: view)
        await makeAds("ep-b2").track(player)
        #expect(delegate.endReasons == [.interrupted], "as for another item")
    }

    @Test func anItemReplacedOnTheSamePlayerMakesShowThrow() async throws {
        let player = try await playingPlayer()
        let ads = await makeAds("ep-item")
        ads.track(player)
        let overlay = try loadedAd(Fixtures.overlayAd(id: "o-ep-item"), of: ads)
        player.replaceCurrentItem(with: AVPlayerItem(url: Self.movie))
        player.play()
        expectContentChanged(overlay, "the AVPlayer plays another item than at track")
    }

    @Test func theSameItemShowsAsBefore() async throws {
        let player = try await playingPlayer()
        let ads = await makeAds("ep-same")
        ads.track(player)
        let overlay = try loadedAd(Fixtures.overlayAd(id: "o-ep-same"), of: ads)
        await sleepMs(50)
        try overlay.show(in: view)
        #expect(overlay.wasShown && overlay.invalidationReason == nil)
        overlay.dismiss()
    }

    /// A custom player that reports the episode it plays.
    final class EpisodePlayer: ContentPlayer {
        var currentTime: TimeInterval = 0
        var isPlaying = true
        var currentItem: AnyHashable?
        init(item: AnyHashable?) { currentItem = item }
    }

    @Test func aCustomPlayersOtherItemMakesShowThrowItsSameItemShows() async throws {
        let player = EpisodePlayer(item: "episode-1")
        let ads = await makeAds("ep-custom")
        ads.track(player)
        let same = try loadedAd(Fixtures.overlayAd(id: "o-ep-custom-same"), of: ads)
        try same.show(in: view)
        #expect(same.wasShown, "the item at track: this episode")
        same.dismiss()
        player.currentItem = "episode-2"
        let other = try loadedAd(Fixtures.overlayAd(id: "o-ep-custom-other"), of: ads)
        expectContentChanged(other, "the custom player reports another item")
    }

    @Test func aCustomPlayerAdoptsTheFirstItemItReportsAfterTrack() async throws {
        let player = EpisodePlayer(item: nil)
        let ads = await makeAds("ep-custom-first")
        ads.track(player)
        player.currentItem = "episode-1"
        let first = try loadedAd(Fixtures.overlayAd(id: "o-ep-custom-first"), of: ads)
        try first.show(in: view)
        #expect(first.wasShown, "no item at track: the first reported is this episode")
        first.dismiss()
        player.currentItem = "episode-1-loop-2"
        let loop = try loadedAd(Fixtures.overlayAd(id: "o-ep-custom-loop"), of: ads)
        expectContentChanged(loop, "a new value for the next loop is another item")
    }

    @Test func aLinearAdIsNotChecked() async throws {
        let player = TestPlayer()
        let episodeA = await makeAds("ep-linear")
        episodeA.track(player)
        let linear = try loadedAd(Fixtures.linearAd(id: "l-ep-linear"), of: episodeA)
        await makeAds("ep-linear-b").track(player)
        try linear.show(from: window.root)
        #expect(linear.wasShown && linear.invalidationReason == nil, "a linear ad covers the content")
        episodeA.destroy()
    }
}
}
